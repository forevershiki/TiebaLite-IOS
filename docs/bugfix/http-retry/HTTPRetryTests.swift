import Foundation

// Offline boundaries for the extracted production declarations. No URLSession or database is opened.
struct TiebaBackgroundSnapshot {
  static let shared = Self()
  let bduss = ""
  let stoken = ""
  let uid = ""
  func commonParams() -> [String: String] { [:] }
}

enum SwiftProtobuf {
  protocol Message {
    func serializedData() throws -> Data
  }
}

struct Tieba_CommonRequest: SwiftProtobuf.Message {
  func serializedData() throws -> Data { Data() }
}

enum TiebaForumAPI {
  static let clientVersion = "test"
  static let v12UserAgent = "test"
  static let deviceModel = "test"
  static func cuidValue() -> String { "" }
  static func commonRequest(clientVersion: String) -> Tieba_CommonRequest { Tieba_CommonRequest() }
}

enum Fixtures {
  static let good = Data([0x01])
  static let stale = Data([0x02])
  static let malformed = Data([0xFF])
  static let businessError = Data([0x03])
  @TaskLocal static var transport: TransportFixture?
  @TaskLocal static var cachedPage: Data?
  @TaskLocal static var cacheAccount: CacheAccountFixture?
  @TaskLocal static var preferInitialCache = false
}

final class CacheAccountFixture: @unchecked Sendable {
  private let lock = NSLock()
  private var current = true

  var isCurrent: Bool {
    lock.withLock { current }
  }

  func switchAccount() {
    lock.withLock { current = false }
  }
}

actor TransportFixture {
  enum Reply: Sendable {
    case http(Int, Data = Data())
    case failure(any Error)
  }

  struct Response: Sendable {
    let statusCode: Int
    let data: Data
  }

  private var replies: [Reply]
  private(set) var requests: [String] = []
  private var firstRequest: CheckedContinuation<Void, Never>?

  init(_ replies: [Reply]) { self.replies = replies }

  func waitForFirstRequest() async {
    if requests.isEmpty {
      await withCheckedContinuation { firstRequest = $0 }
    }
  }

  func send(_ request: URLRequest) throws -> Response {
    requests.append("\(request.httpMethod ?? "") \(request.url!.path)")
    firstRequest?.resume()
    firstRequest = nil
    precondition(!replies.isEmpty, "Unexpected extra request: \(requests)")
    switch replies.removeFirst() {
    case let .http(status, data): return Response(statusCode: status, data: data)
    case .failure(let error): throw error
    }
  }
}

final class TiebaHttpClient: Sendable {
  static let shared = TiebaHttpClient()

  func perform(_ request: URLRequest) async throws -> TransportFixture.Response {
    try await Fixtures.transport!.send(request)
  }
}

final class TiebaPageCache: Sendable {
  static let shared = TiebaPageCache()

  static func scope(kind: TiebaPageCacheKind, pageKey: String) -> TiebaPageCacheScope {
    TiebaPageCacheScope(kind: kind, accountKey: "anon", pageKey: pageKey)
  }
  static func isScopeCurrent(_ scope: TiebaPageCacheScope) -> Bool { Fixtures.cacheAccount?.isCurrent ?? true }
  static func nowMilliseconds() -> Int64 { 100 }
  func takeInitialSeed(scope: TiebaPageCacheScope) -> Bool { Fixtures.preferInitialCache }
  func load(scope: TiebaPageCacheScope, maxStale: TimeInterval) async -> TiebaPageCacheEntry? {
    Fixtures.cachedPage.map {
      TiebaPageCacheEntry(payload: $0, fetchedAt: 0, expiresAt: Fixtures.preferInitialCache ? 100 : 0, lastAccessAt: 0)
    }
  }
  func storeInBackground(scope: TiebaPageCacheScope, payload: Data, ttl: TimeInterval) {}
}

struct TiebaForumFeedPage {
  let payload: Data
}

enum TiebaForumFeedAPI {
  static func fetchRawPageData(forumName: String, page: Int, sortType: Int, isGood: Bool, classifyId: String?) async throws -> Data {
    try await TiebaForumAPI.protoPost(path: "/c/f/frs/page", cmd: "test") { $0 }
  }

  static func decodePageData(_ data: Data, page: Int, forumName: String) async throws -> TiebaForumFeedPage {
    if data == Fixtures.malformed { throw TiebaProtoError.invalidWire("fixture") }
    if data == Fixtures.businessError {
      try TiebaViewModelMapper.assertProtoSuccess(["error": ["errorCode": 340001, "errorMsg": "fixture"]])
    }
    if data == Fixtures.stale {
      Fixtures.cacheAccount?.switchAccount()
    }
    return TiebaForumFeedPage(payload: data)
  }

  static func scheduleRevalidate(scope: TiebaPageCacheScope, forumName: String, page: Int, sortType: Int, isGood: Bool, classifyId: String?) {
    preconditionFailure("The fixture does not schedule background revalidation")
  }
}

private struct CheckFailure: Error, CustomStringConvertible {
  let description: String
}

@main
@MainActor
enum HTTPRetryTests {
  static func main() async throws {
    let ok = TransportFixture([.http(200, Fixtures.good)])
    try expect(try await read(ok) == Fixtures.good, "HTTP 200 must return its response")
    try expect(await ok.requests.count == 1, "HTTP 200 must send once")

    for status in [500, 502, 503, 504, 599] {
      let recovered = TransportFixture([.http(status), .http(200, Fixtures.good)])
      try expect(try await read(recovered) == Fixtures.good, "HTTP \(status) must recover")
      try expect(await recovered.requests.count == 2, "HTTP \(status) must send twice")
    }

    for reply in [TransportFixture.Reply.failure(TiebaForumAPIError.http(503)),
                  TransportFixture.Reply.failure(URLError(.timedOut)),
                  TransportFixture.Reply.failure(URLError(.networkConnectionLost))] {
      let recovered = TransportFixture([reply, .http(200, Fixtures.good)])
      try expect(try await read(recovered) == Fixtures.good, "Legacy HTTP and transient URL errors must recover")
      try expect(await recovered.requests.count == 2, "Legacy HTTP and transient URL errors must send twice")
    }

    let exhausted = TransportFixture([.http(503), .http(503), .http(504)])
    try await expectError("Exhausted read") { _ = try await load(exhausted) }
      matches: { hasStatus($0, 504) }
    try expect(await exhausted.requests.count == 3, "Exhausted read must send at most three times")

    let fallingBack = TransportFixture([.http(503), .http(503), .http(503)])
    try await Fixtures.$cachedPage.withValue(Fixtures.stale) {
      try expect(try await load(fallingBack) == Fixtures.stale, "Exhausted read must use available stale data")
    }
    try expect(await fallingBack.requests.count == 3, "Stale data must be used after retry exhaustion")

    let accountChanged = TransportFixture([.http(503), .http(503), .http(504)])
    try await Fixtures.$cacheAccount.withValue(CacheAccountFixture()) {
      try await Fixtures.$cachedPage.withValue(Fixtures.stale) {
        try await expectError("Account changed during cache decode") { _ = try await load(accountChanged) }
          matches: { hasStatus($0, 504) }
      }
    }
    try expect(await accountChanged.requests.count == 3, "Old account data must not replace the final HTTP error")

    let cacheFirst = TransportFixture([])
    let changedOnCacheFirst = TransportFixture([.http(200, Fixtures.good)])
    try await Fixtures.$preferInitialCache.withValue(true) {
      try await Fixtures.$cachedPage.withValue(Fixtures.stale) {
        try expect(try await load(cacheFirst) == Fixtures.stale, "A fresh seed still returns immediately")
        try await Fixtures.$cacheAccount.withValue(CacheAccountFixture()) {
          try expect(try await load(changedOnCacheFirst) == Fixtures.good, "A seed from the previous account must be discarded")
        }
      }
    }
    try expect(await cacheFirst.requests.isEmpty, "A fresh seed must keep the cache-first path")
    try expect(await changedOnCacheFirst.requests.count == 1, "An invalidated seed must use the network")

    for status in [400, 401, 403, 404, 429, 600] {
      let refused = TransportFixture([.http(status)])
      try await Fixtures.$cachedPage.withValue(Fixtures.stale) {
        try await expectError("HTTP \(status)") { _ = try await load(refused) }
          matches: { hasStatus($0, status) }
      }
      try expect(await refused.requests.count == 1, "HTTP \(status) must send once")
    }

    let tlsError = URLError(.secureConnectionFailed)
    let failedTLS = TransportFixture([.failure(tlsError)])
    try await Fixtures.$cachedPage.withValue(Fixtures.stale) {
      try expect(try await load(failedTLS) == Fixtures.stale, "TLS failures retain cache fallback")
    }
    try expect(await failedTLS.requests.count == 1, "TLS handshake failure must send once")

    let cancelledErrors: [(any Error, (any Error) -> Bool)] = [
      (CancellationError(), { $0 is CancellationError }),
      (URLError(.cancelled), { ($0 as? URLError)?.code == .cancelled }),
      (TiebaClientError.cancelled, {
        if case .cancelled? = $0 as? TiebaClientError { return true }
        return false
      }),
    ]
    for (error, matches) in cancelledErrors {
      let cancelled = TransportFixture([.failure(error)])
      try await Fixtures.$cachedPage.withValue(Fixtures.stale) {
        try await expectError("Cancelled request", { _ = try await load(cancelled) }, matches: matches)
      }
      try expect(await cancelled.requests.count == 1, "Cancellation must send once and skip stale data")
    }

    let beforeSend = TransportFixture([])
    let preCancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await read(beforeSend) { _ in
        preconditionFailure("Cancelled request must not serialize Protobuf")
      }
    }
    try await expectError("Cancelled before send") { _ = try await preCancelled.value }
      matches: { $0 is CancellationError }
    try expect(await beforeSend.requests.isEmpty, "A pre-cancelled task must never send")

    let duringDelay = TransportFixture([.http(503)])
    let retrying = Task {
      try await Fixtures.$cachedPage.withValue(Fixtures.stale) { try await load(duringDelay) }
    }
    await duringDelay.waitForFirstRequest()
    try await Task.sleep(nanoseconds: 50_000_000)
    retrying.cancel()
    try await expectError("Cancelled during backoff") { _ = try await retrying.value }
      matches: { $0 is CancellationError }
    try expect(await duringDelay.requests.count == 1, "Cancelling backoff must prevent any further send")

    let malformed = TransportFixture([.http(200, Fixtures.malformed)])
    try await expectError("Malformed Protobuf") { _ = try await load(malformed) }
      matches: { $0 is TiebaProtoError }
    try expect(await malformed.requests.count == 1, "Decode failure must send once")
    let malformedWithCache = TransportFixture([.http(200, Fixtures.malformed)])
    try await Fixtures.$cachedPage.withValue(Fixtures.stale) {
      try expect(try await load(malformedWithCache) == Fixtures.stale, "Existing decode-error fallback must still work")
    }
    try expect(await malformedWithCache.requests.count == 1, "Decode fallback must send once")

    let businessError = TransportFixture([.http(200, Fixtures.businessError)])
    try await Fixtures.$cachedPage.withValue(Fixtures.stale) {
      try await expectError("Business error 340001") { _ = try await load(businessError) }
        matches: { ($0 as? TiebaViewModelError)?.code == 340001 }
    }
    try expect(await businessError.requests == ["POST /c/f/frs/page"], "Business error must not trigger another forum request")

    let failedWrite = TransportFixture([.http(503)])
    try await Fixtures.$transport.withValue(failedWrite) {
      try await expectError("Unfollow HTTP 503") {
        try await TiebaForumFeedAPI.unlike(forumId: "1", forumName: "yy小说吧", tbs: "test")
      } matches: { hasStatus($0, 503) }
    }
    try expect(await failedWrite.requests == ["POST /c/c/forum/unfavolike"], "Unfollow must send once")
    print("PASS: offline HTTP retry, cancellation, cache fallback and write isolation")
  }

  // Request construction can leave the test runner's MainActor.
  private nonisolated static func read(
    _ transport: TransportFixture,
    makeRequest: @Sendable (Tieba_CommonRequest) -> Tieba_CommonRequest = { $0 }
  ) async throws -> Data {
    try await Fixtures.$transport.withValue(transport) {
      try await TiebaForumAPI.protoPost(path: "/c/f/frs/page", cmd: "test", makeRequest: makeRequest)
    }
  }

  private static func load(_ transport: TransportFixture) async throws -> Data {
    try await Fixtures.$transport.withValue(transport) {
      try await TiebaForumFeedAPI.page(forumName: "yy小说吧", page: 1, sortType: -1, isGood: false, classifyId: nil).payload
    }
  }

  private static func hasStatus(_ error: any Error, _ status: Int) -> Bool {
    if case .httpStatus(let value)? = error as? TiebaClientError { return value == status }
    return false
  }

  private static func expect(_ condition: Bool, _ label: String) throws {
    guard condition else { throw CheckFailure(description: label) }
  }

  private static func expectError(
    _ label: String,
    _ operation: @MainActor () async throws -> Void,
    matches: (any Error) -> Bool
  ) async throws {
    do {
      try await operation()
    } catch {
      try expect(matches(error), "\(label) returned \(error)")
      return
    }
    throw CheckFailure(description: "\(label) unexpectedly succeeded")
  }
}
