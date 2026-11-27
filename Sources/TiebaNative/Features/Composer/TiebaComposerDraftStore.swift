import Foundation

struct TiebaComposerDraftStore {
  let directory: URL

  static var live: Self {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return Self(directory: support.appendingPathComponent("TiebaComposerDrafts", isDirectory: true))
  }

  func load(accountID: String, target: TiebaComposerTarget) throws -> TiebaComposerDraft {
    let url = try file(accountID: accountID, target: target)
    do {
      return try PropertyListDecoder().decode(TiebaComposerDraft.self, from: Data(contentsOf: url))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return TiebaComposerDraft()
    }
  }

  func save(_ draft: TiebaComposerDraft, accountID: String, target: TiebaComposerTarget) throws {
    if draft.isEmpty {
      try remove(accountID: accountID, target: target)
      return
    }
    let url = try file(accountID: accountID, target: target)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #if os(iOS)
    // Avoid putting user-composed text and images into device backups.
    var folder = directory
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try folder.setResourceValues(resourceValues)
    let options: Data.WritingOptions = [.atomic, .completeFileProtection]
    #else
    let options: Data.WritingOptions = .atomic
    #endif
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try encoder.encode(draft).write(to: url, options: options)
  }

  func remove(accountID: String, target: TiebaComposerTarget) throws {
    let url = try file(accountID: accountID, target: target)
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
      return
    }
  }

  func removeAll() throws {
    do {
      try FileManager.default.removeItem(at: directory)
    } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
      return
    }
  }

  static func key(accountID: String, target: TiebaComposerTarget) throws -> String {
    guard TiebaComposerTarget.isPositiveID(accountID) else { throw TiebaComposerFailure.login }
    try target.validate()
    return ([accountID] + target.draftComponents).joined(separator: "-")
  }

  private func file(accountID: String, target: TiebaComposerTarget) throws -> URL {
    directory.appendingPathComponent(try Self.key(accountID: accountID, target: target) + ".plist")
  }
}

@MainActor
final class TiebaComposerEditorState {
  private let store: TiebaComposerDraftStore
  let accountID: String
  let target: TiebaComposerTarget
  private(set) var draft: TiebaComposerDraft
  private var saved: TiebaComposerDraft

  init(store: TiebaComposerDraftStore, accountID: String, target: TiebaComposerTarget) throws {
    self.store = store
    self.accountID = accountID
    self.target = target
    draft = try store.load(accountID: accountID, target: target)
    saved = draft
  }

  var hasChanges: Bool { draft != saved }

  func edit(title: String, body: String) {
    draft.title = title
    draft.body = body
  }

  func setImages(_ images: [Data]) { draft.images = images }

  func save() throws {
    guard hasChanges else { return }
    try persist(draft)
  }

  func setOutcomeUnknown(_ unknown: Bool) throws {
    var next = draft
    next.outcomeUnknown = unknown
    try persist(next)
  }

  func clear() throws {
    try persist(TiebaComposerDraft())
  }

  func submit(
    through submission: TiebaComposerSubmission, identity: TiebaComposerIdentity?,
    validateSession: () throws -> Void, progress: (TiebaComposerProgress) -> Void
  ) async throws -> (destination: TiebaComposerDestination, draftCleared: Bool) {
    let snapshot = draft
    try save()
    var dispatched = false
    let receipt: TiebaComposerReceipt
    do {
      receipt = try await submission.submit(
        target: target, draft: snapshot, identity: identity, validateSession: validateSession,
        willSend: {
          try self.setOutcomeUnknown(true)
          dispatched = true
        }, progress: progress
      )
    } catch {
      if dispatched, (error as? TiebaComposerFailure) != .unknown {
        try setOutcomeUnknown(false)
      }
      throw error
    }
    let destination = TiebaComposerProtocol.destination(for: target, receipt: receipt)
    do {
      try clear()
      return (destination, true)
    } catch {
      return (destination, false)
    }
  }

  private func persist(_ value: TiebaComposerDraft) throws {
    do {
      try store.save(value, accountID: accountID, target: target)
      draft = value
      saved = value
    } catch {
      throw TiebaComposerFailure.draft
    }
  }
}
