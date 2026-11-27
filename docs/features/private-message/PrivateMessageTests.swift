import Foundation
import SQLite3

private enum TestError: Error {
  case assertion(String)
}

@main
enum PrivateMessageTests {
  static func main() async throws {
    let path = CommandLine.arguments[1]
    let raw = try Data(contentsOf: URL(fileURLWithPath: path))
    let hex = try JSONDecoder().decode([String: String].self, from: raw)
    let fixtures = try hex.mapValues(decodeHex)
    let scope = try TiebaPrivateMessageScope(accountID: 44, groupID: 600)
    try access()
    let batch = try payloads(fixtures, scope: scope)
    try sends(fixtures, scope: scope)
    try await cache(batch)
    print("Private-message offline regressions passed")
  }

  private static func access() throws {
    let legacy = URL(string: "ws://im.tieba.baidu.com:8000/")!
    let tls = URL(string: "wss://im.tieba.baidu.com/")!
    try expectError(.loginRequired) { _ = try TiebaPrivateMessageAccess.endpoint(accountID: nil, candidate: tls) }
    try expectError(.unsafeEndpoint) {
      _ = try TiebaPrivateMessageAccess.endpoint(accountID: 44, candidate: legacy)
    }
    try expectError(.unverifiedEndpoint) { _ = try TiebaPrivateMessageAccess.endpoint(accountID: 44, candidate: tls) }
    for raw in [
      "wss://im.tieba.baidu.com.example.invalid/", "wss://peer@im.tieba.baidu.com/",
      "wss://im.tieba.baidu.com/?q=1", "wss://im.tieba.baidu.com/#fragment",
    ] {
      let unsafe = URL(string: raw)!
      try expectError(.unsafeEndpoint) {
        _ = try TiebaPrivateMessageAccess.endpoint(accountID: 44, candidate: unsafe)
      }
    }
  }

  private static func payloads(
    _ fixtures: [String: Data], scope: TiebaPrivateMessageScope
  ) throws -> TiebaPrivateMessageBatch {
    let batch = try TiebaPrivateMessageProtocol.messages(fixture(fixtures, "groupMessages"), scope: scope)
    try expect(batch.incoming.map(\.id) == [9_007_199_254_740_999, 9_007_199_254_741_000, 9_007_199_254_740_998],
      "only verified private group and incoming message kinds are projected")
    try expect(batch.incoming.map(\.senderID) == [45, 45, 46], "peer identity uses the numeric sender")
    try expect(batch.incoming[0].content == .text("合成私信 🌱"), "UTF-8 text survives the wire")
    try expect(batch.incoming[1].content == .unsupported(wireType: 18), "unknown content is never used as text")
    try expect(batch.incoming[1].content.preview == "暂不支持的私信类型", "unknown type has safe placeholder")
    try expect(batch.peerReads == [.init(peerID: 45, throughID: 9_007_199_254_740_999)],
      "foreign-group receipts cannot become private read positions")
    let hints = try TiebaPrivateMessageProtocol.pushHints(fixture(fixtures, "pushHints"), scope: scope)
    try expect(hints == [.init(messageID: 10, kind: 22)], "duplicate hints and other groups are filtered")
    try expectError(.rejected(14)) {
      _ = try TiebaPrivateMessageProtocol.messages(fixture(fixtures, "groupRejected"), scope: scope)
    }
    for invalid in [Data(), Data([0x12, 0x04, 0x0A]), Data(repeating: 0xff, count: 10),
                    Data(repeating: 0, count: 2 * 1024 * 1024 + 1)] {
      try expectError(.malformedPayload) {
        _ = try TiebaPrivateMessageProtocol.messages(invalid, scope: scope)
      }
    }
    return batch
  }

  private static func sends(_ fixtures: [String: Data], scope: TiebaPrivateMessageScope) throws {
    try expectError(.invalidIdentity) {
      _ = try TiebaPrivateSendExpectation(scope: scope, peerID: 44, recordID: 953, requestID: 9)
    }
    let expected = try TiebaPrivateSendExpectation(scope: scope, peerID: 45, recordID: 953, requestID: 9)
    let confirm = try fixture(fixtures, "sendConfirmed")
    let cases: [(String, TiebaPrivateSendAttempt.State)] = [
      ("sendConfirmed", .confirmed(messageID: 9_007_199_254_740_999)),
      ("sendBlocked", .rejected(code: 23)),
      ("sendRejected", .rejected(code: -7)),
      ("sendLegacy", .unknown),
      ("sendWrongPeer", .unknown),
    ]
    for (name, state) in cases {
      var attempt = TiebaPrivateSendAttempt(expectation: expected)
      try expect(attempt.state == .pending, "starts pending")
      try expect(attempt.begin(), "explicit dispatch is accepted")
      try expect(!attempt.begin(), "repeat click cannot redispatch")
      try expect(!attempt.accept(command: TiebaPrivateMessageProtocol.pushCommand, requestID: 9, payload: confirm),
        "push is not a send receipt")
      try expect(!attempt.accept(command: 205001, requestID: 8, payload: confirm), "wrong request cannot acknowledge")
      try expect(attempt.accept(command: 205001, requestID: 9, payload: fixture(fixtures, name)), "matched receipt consumed")
      try expect(attempt.state == state && !attempt.begin(), "expected final state")
    }
    var disconnected = TiebaPrivateSendAttempt(expectation: expected)
    _ = disconnected.begin()
    disconnected.loseConfirmation()
    try expect(disconnected.state == .unknown && !disconnected.begin(), "connection loss or timeout never retries")
    try expect(!disconnected.accept(command: 205001, requestID: 9, payload: confirm), "late disconnected response must not update new session")
  }

  private static func cache(_ batch: TiebaPrivateMessageBatch) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = TiebaPrivateMessageCache(scope: batch.scope, baseDirectory: folder)
    let otherScope = try TiebaPrivateMessageScope(accountID: 47, groupID: batch.scope.groupID)
    let other = TiebaPrivateMessageCache(scope: otherScope, baseDirectory: folder)
    let sameAccountOtherGroup = try TiebaPrivateMessageScope(accountID: 44, groupID: 601)
    let changedGroup = TiebaPrivateMessageCache(scope: sameAccountOtherGroup, baseDirectory: folder)
    let added = try await store.store(.init(
      scope: batch.scope, incoming: Array(batch.incoming.reversed()), peerReads: batch.peerReads
    ))
    try expect(added.affectedPeerIDs == [45, 46] && added.insertedMessageIDs.count == 3, "committed change identifies peers only")
    let repeated = try await store.store(batch)
    try expect(repeated.insertedMessageIDs.isEmpty, "stable server IDs remove duplicates")
    let summaries = try await store.conversations()
    try expect(summaries.map(\.peerID) == [45, 46] && summaries.map(\.localUnreadCount) == [2, 1],
      "list order is deterministic and peer receipt does not clear local unread")
    let first = try await store.history(peerID: 45, limit: 1)
    let second = try await store.history(peerID: 45, before: first.next, limit: 1)
    try expect(first.messages.map(\.id) == [9_007_199_254_741_000] && first.next != nil, "latest same-second message is first")
    try expect(second.messages.map(\.id) == [9_007_199_254_740_999] && second.next == nil, "history cursor is exclusive")
    try expect(try await store.conversations() == summaries, "history reads do not mark messages read")
    let wrongPeer = try await store.markLocalRead(peerID: 46, through: first.messages[0].id)
    try expect(!wrongPeer, "cannot mark another peer's message")
    try expect(try await store.markLocalRead(peerID: 45, through: first.messages[0].id), "explicit local read changes watermark")
    let older = try await store.markLocalRead(peerID: 45, through: second.messages[0].id)
    try expect(!older, "watermark does not regress")
    try expect(try await store.conversations().map(\.localUnreadCount) == [0, 1], "local read is scoped to one peer")
    let otherConversations = try await other.conversations()
    let changedGroupConversations = try await changedGroup.conversations()
    try expect(otherConversations.isEmpty && changedGroupConversations.isEmpty, "accounts and IM groups start with independent caches")
    do {
      _ = try await other.store(batch)
      throw TestError.assertion("cross-account batch unexpectedly succeeded")
    } catch TiebaPrivateMessageError.invalidIdentity {}

    let valid = TiebaPrivateIncomingMessage(id: 777, senderID: 45, createdAt: 20, content: .text("内嵌\0文本"))
    let invalid = TiebaPrivateIncomingMessage(id: -1, senderID: 45, createdAt: 20, content: .text("reject"))
    do {
      _ = try await store.store(.init(scope: batch.scope, incoming: [valid, invalid], peerReads: []))
      throw TestError.assertion("expected invalid batch to roll back")
    } catch TiebaPrivateMessageError.invalidIdentity {}
    try expect(try await store.history(peerID: 45).messages.count == 2, "partial transaction rolls back")
    _ = try await store.store(.init(scope: batch.scope, incoming: [valid], peerReads: []))
    await store.close()
    do {
      _ = try await store.conversations()
      throw TestError.assertion("logged-out instance unexpectedly reopened")
    } catch TiebaPrivateMessageError.cacheUnavailable {}
    let reopened = TiebaPrivateMessageCache(scope: batch.scope, baseDirectory: folder)
    try expect(try await reopened.history(peerID: 45).messages.last?.content == valid.content, "protected cache round trips text")
    _ = try await other.store(.init(scope: otherScope, incoming: [valid], peerReads: []))
    try await reopened.clear()
    try expect(try await other.history(peerID: 45).messages.count == 1, "clearing one account preserves another account")
    let fresh = TiebaPrivateMessageCache(scope: batch.scope, baseDirectory: folder)
    try expect(try await fresh.conversations().isEmpty, "purged account starts empty")

    // A newer independent cache schema must fail closed without erasing its tables.
    let futureScope = try TiebaPrivateMessageScope(accountID: 99, groupID: 600)
    let futureDirectory = folder.appendingPathComponent("99")
    try FileManager.default.createDirectory(at: futureDirectory, withIntermediateDirectories: true)
    let path = futureDirectory.appendingPathComponent("inbox.sqlite3").path
    var db: OpaquePointer?
    try expect(sqlite3_open(path, &db) == SQLITE_OK, "prepare future schema")
    try expect(sqlite3_exec(db, "CREATE TABLE keep (value TEXT); PRAGMA user_version = 2;", nil, nil, nil) == SQLITE_OK,
      "future schema written")
    sqlite3_close(db)
    let future = TiebaPrivateMessageCache(scope: futureScope, baseDirectory: folder)
    do {
      _ = try await future.conversations()
      throw TestError.assertion("future schema unexpectedly downgraded")
    } catch TiebaPrivateMessageError.cacheUnavailable {}
    try expect(FileManager.default.fileExists(atPath: path), "future cache file remains")
  }

  private static func fixture(_ fixtures: [String: Data], _ name: String) throws -> Data {
    guard let data = fixtures[name] else { throw TestError.assertion("missing fixture \(name)") }
    return data
  }

  private static func decodeHex(_ text: String) throws -> Data {
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
      guard let end = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
        let byte = UInt8(text[index..<end], radix: 16) else { throw TestError.assertion("invalid fixture hex") }
      bytes.append(byte)
      index = end
    }
    return Data(bytes)
  }

  private static func expect(_ condition: Bool, _ detail: String) throws {
    guard condition else { throw TestError.assertion(detail) }
  }

  private static func expectError(_ error: TiebaPrivateMessageError, _ operation: () throws -> Void) throws {
    do {
      try operation()
      throw TestError.assertion("missing expected error \(error)")
    } catch let actual as TiebaPrivateMessageError {
      try expect(actual == error, "expected \(error), got \(actual)")
    }
  }
}
