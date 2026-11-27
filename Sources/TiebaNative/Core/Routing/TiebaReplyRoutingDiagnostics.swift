#if DEBUG
import Foundation
import os

enum TiebaReplyRoutingDiagnostics {
  static let presenceKey = "_replyRoutingPresence"
  private static let log = Logger(subsystem: "com.tiebalite.app", category: "reply-routing")
  private static let state = TiebaMutex(State(
    enabled: ProcessInfo.processInfo.arguments.contains("-TiebaDebugReplyRouting")
  ))

  private struct State: Sendable {
    var enabled: Bool
    var generation = 0
    var latestFailure: String?
  }

  static var enabled: Bool {
    get { state.withLock { $0.enabled } }
    set {
      state.withLock {
        guard $0.enabled != newValue else { return }
        $0.enabled = newValue
        $0.generation += 1
        $0.latestFailure = nil
      }
    }
  }

  static var latestFailure: String? { state.withLock { $0.latestFailure } }

  enum Source: String {
    case personalized, concern, hot, topic, profile
  }

  struct Tap: Sendable {
    fileprivate let generation: Int
    fileprivate let summary: String

    fileprivate func saveFailure(_ details: String) {
      TiebaReplyRoutingDiagnostics.state.withLock {
        guard $0.enabled, $0.generation == generation else { return }
        $0.latestFailure = summary + "\n" + details
      }
    }
  }

  final class PageAttempt: Sendable {
    private let tap: Tap
    private let stages = TiebaMutex([String]())

    init(_ tap: Tap) { self.tap = tap }

    func request(_ request: TiebaThreadPageRequest) {
      record("request /c/f/pb/page \(Self.coordinates(request))")
    }

    func response(_ request: TiebaThreadPageRequest, code: Int32) {
      record("response /c/f/pb/page \(Self.coordinates(request)) code=\(code)")
    }

    func saveFailure() {
      let trace = stages.withLock { $0 }
      tap.saveFailure((trace + ["result=page-load-failed"]).joined(separator: "\n"))
    }

    private func record(_ stage: String) {
      guard TiebaReplyRoutingDiagnostics.state.withLock({ $0.enabled && $0.generation == tap.generation }) else { return }
      stages.withLock { $0.append(stage) }
      TiebaReplyRoutingDiagnostics.log.debug("\(stage, privacy: .public)")
    }

    private static func coordinates(_ request: TiebaThreadPageRequest) -> String {
      let pid = TiebaReplyRoutingDiagnostics.id(request.postID)
      let fid = TiebaReplyRoutingDiagnostics.id(request.forumID)
      return "kz=\(request.threadID) pid=\(pid) fid=\(fid) pn=\(request.pageNumber)"
    }
  }

  // Navigation constructs the detail controller synchronously. The controller
  // retains this tap, and binds each initial load or refresh to its own attempt.
  @TaskLocal static var navigationTap: Tap? = nil
  @TaskLocal static var pageAttempt: PageAttempt? = nil

  /// Capture allowlisted fields after Protobuf normalization, before mapping.
  static func rawFields(_ raw: [String: Any], forum: [String: Any]? = nil) -> String {
    let forumIDs = ["forumId", "forum_id", "fid"]
    let keys = ["id", "threadId", "thread_id", "tid", "postId", "post_id", "firstPostId", "first_post_id",
                "isShareThread", "is_share_thread", "threadTypes", "thread_types"] + forumIDs
    func fields(_ row: [String: Any], _ keys: [String]) -> String {
      let present = keys.compactMap { key in row[key].map { "\(key)=\(id($0))" } }
      return present.isEmpty ? "-" : present.joined(separator: " ")
    }
    var result = ["raw: \(fields(raw, keys))"]
    for key in ["originThreadInfo", "origin_thread_info"] where raw[key] != nil {
      result.append("raw.\(key): \(fields(raw[key] as? [String: Any] ?? [:], ["tid", "pid"] + forumIDs))")
    }
    for key in ["forumInfo", "forum_info", "forum"] where raw[key] != nil {
      result.append("raw.\(key): \(fields(raw[key] as? [String: Any] ?? [:], ["id"] + forumIDs))")
    }
    if let forum { result.append("raw.containerForum: \(fields(forum, ["id"] + forumIDs))") }
    return result.joined(separator: "\n")
  }

  static func addingConcernPost(_ post: [String: Any]?, to row: [String: Any]) -> [String: Any] {
    guard let post, let raw = row[presenceKey] as? String else { return row }
    var row = row
    row[presenceKey] = raw + "\nraw.concernPost: present=true id=\(id(post["id"]))"
    return row
  }

  static func card(_ row: [String: Any], target: TiebaThreadCardTarget?, source: Source) -> Tap? {
    guard let generation = state.withLock({ $0.enabled ? $0.generation : nil }) else { return nil }
    let origin = TiebaViewModelMapper.originThreadInfo(row)
    let raw = row[presenceKey] as? String ?? "raw: unavailable"
    let post = id(row["postId"])
    let firstPost = id(row["firstPostId"])
    let share = row["isShareThread"] as? Bool == true
    let hasReplyAnchor = post != "-" && post != firstPost
    let cardKind = share ? "reference" : (hasReplyAnchor ? "reply" : "unknown")
    let kind = target?.kind.rawValue ?? cardKind
    let mapped = [
      "id=\(id(row["id"]))", "threadId=\(id(row["threadId"]))",
      "postId=\(post)", "firstPostId=\(firstPost)",
      "forumId=\(id(row["forumId"]))", "routingForumId=\(id(row["routingForumId"]))",
      "originTid=\(id(origin?["threadId"]))", "originPid=\(id(origin?["pid"]))",
      "originFid=\(id(origin?["forumId"]))",
    ].joined(separator: " ")
    let summary = """
      tap source=\(source.rawValue) kind=\(kind) hasOrigin=\(origin != nil) isShare=\(share)
      \(raw)
      mapped: \(mapped)
      route: kz=\(id(target?.threadId)) pid=\(id(target?.postId)) fid=\(id(target?.forumId))
      """
    log.debug("\(summary, privacy: .public)")
    let tap = Tap(generation: generation, summary: summary)
    if target == nil { tap.saveFailure("result=unresolved request=none") }
    return tap
  }

  private static func id(_ value: Any?) -> String {
    TiebaRoutePath.positiveID(value).map { String($0) } ?? "-"
  }
}
#endif
