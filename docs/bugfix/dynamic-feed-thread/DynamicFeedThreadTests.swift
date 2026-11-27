import Foundation
import SwiftProtobuf
import TiebaNativeProto

private actor PageTransport {
  static let shared = PageTransport()
  private var responses: [Result<Data, TiebaClientError>] = []
  private var sent: [Data] = []

  func arrange(_ responses: [Result<Data, TiebaClientError>]) {
    self.responses = responses
    sent = []
    TiebaPageCache.shared.reset()
  }

  func send(_ request: Data) throws -> Data {
    sent.append(request)
    guard !responses.isEmpty else { throw FixtureFailure("Unexpected extra request") }
    return try responses.removeFirst().get()
  }

  func pageRequests() throws -> [Tieba_PbPage_PbPageRequestData] {
    try sent.map { try Tieba_PbPage_PbPageRequest(serializedBytes: $0).data }
  }
}

enum TiebaForumAPI {
  static func protoPost<Request: SwiftProtobuf.Message>(
    path: String, cmd: String, makeRequest: (Tieba_CommonRequest) -> Request
  ) async throws -> Data {
    guard path == "/c/f/pb/page", cmd == "302001&format=protobuf" else {
      throw FixtureFailure("Unexpected endpoint: \(path) \(cmd)")
    }
    let bytes = try makeRequest(Tieba_CommonRequest()).serializedData()
    return try await PageTransport.shared.send(bytes)
  }
}

final class TiebaPageCache: @unchecked Sendable {
  static let shared = TiebaPageCache()
  private let lock = NSLock()
  private var entries: [TiebaPageCacheScope: TiebaPageCacheEntry] = [:]

  static func nowMilliseconds() -> Int64 { 0 }
  static func scope(kind: TiebaPageCacheKind, pageKey: String) -> TiebaPageCacheScope {
    .init(kind: kind, accountKey: "synthetic", pageKey: pageKey)
  }
  static func isScopeCurrent(_ scope: TiebaPageCacheScope) -> Bool { scope.accountKey == "synthetic" }
  static func debugDidDecode(kind: TiebaPageCacheKind, pageKey: String, started: UInt64) {}
  func beginRevalidation(scope: TiebaPageCacheScope) -> Bool { false }
  func endRevalidation(scope: TiebaPageCacheScope) {}

  func reset() { lock.withLock { entries.removeAll() } }
  func load(scope: TiebaPageCacheScope, maxStale: TimeInterval) async -> TiebaPageCacheEntry? {
    lock.withLock { entries[scope] }
  }
  func store(scope: TiebaPageCacheScope, payload: Data, ttl: TimeInterval) {
    lock.withLock {
      entries[scope] = .init(payload: payload, fetchedAt: 0, expiresAt: 100, lastAccessAt: 0)
    }
  }
  func storeInBackground(scope: TiebaPageCacheScope, payload: Data, ttl: TimeInterval) {
    store(scope: scope, payload: payload, ttl: ttl)
  }
}

private struct FixtureFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

@main
struct DynamicFeedThreadTests {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure(message) }
  }

  @MainActor
  static func main() async throws {
    try formatAndRoute()
    try await pageRequestAndErrors()
    print("PASS: display, canonical identity, typed routes and serialized thread requests/responses")
  }

  @MainActor
  static func formatAndRoute() throws {
    for (raw, title) in [("yy小说吧", "yy小说吧"), ("yy小说", "yy小说吧"), ("百度", "百度吧"), ("", "")] {
      try expect(TiebaForumFormat.displayName(raw) == title, "forum title for \(raw)")
    }
    try expect(TiebaForumFormat.displayName("", empty: "未知") == "未知", "explicit fallback")
    try expect(TiebaForumFormat.displayName("吧吧") == "吧吧", "legitimate repeated glyphs")
    let nested: [String: Any] = ["id": "31", "name": "yy小说吧"]
    let recommendRaw: [String: Any] = [
      "id": "456", "threadId": "0", "thread_id": "123", "post_id": "456",
      "forumId": 0, "forumName": "", "forum_info": nested,
    ]
    let items = TiebaViewModelMapper.mapFeedThreadItems(threadList: [recommendRaw], userList: [])
    let recommend = items.first?["threadInfo"] as? [String: Any] ?? [:]
    let replyRoute = TiebaRoute.thread(id: "123", postId: "456", forumId: "31", forumName: "yy小说吧")
    try expect(TiebaThreadCardTarget.card(recommend)?.route() == replyRoute, "recommendation reply")

    let followData = TiebaViewModelMapper.mapUserLikeData([
      "threadList": [["thread_list": ["tid": "123", "id": "456", "post_id": "456"], "forum": nested]],
    ])
    let follow = (followData["items"] as? [[String: Any]])?.first?["threadInfo"] as? [String: Any] ?? [:]
    try expect(TiebaThreadCardTarget.card(follow)?.route() == replyRoute, "followed user reply")

    let hot = TiebaViewModelMapper.mapProtoThread(["id": "123", "forumInfo": nested])
    let forumPage = TiebaViewModelMapper.mapFrsPageData([
      "threadList": [["id": "123", "post_id": "789", "first_post_id": "789"]], "forum": nested,
    ], page: 1, forumName: "yy小说吧")
    let forum = (forumPage["threads"] as? [[String: Any]])?.first ?? [:]
    let search: [String: Any] = ["threadId": "123", "forumId": "31", "forumName": "yy小说吧"]
    let history = TiebaRoute.thread(id: "123", forumId: "31", forumName: "yy小说吧")
    for row in [hot, forum, search] {
      try expect(TiebaThreadCardTarget.card(row)?.route() == history, "topic identity across entry shapes")
    }
    let favorite = TiebaRoute.thread(id: "123", fromFavorites: true, forumId: "31", forumName: "yy小说吧")
    try expect(TiebaThreadCardTarget.card(search)?.route(fromFavorites: true) == favorite, "favorites preferences")
    var profile = search
    profile["postId"] = "456"
    try expect(TiebaThreadCardTarget.card(profile)?.route() == replyRoute, "profile reply anchor")

    let identities = ["yy小说", "yy小说吧", "小说 A&B#50%/讨论%2F吧"].map {
      TiebaRoute.thread(id: "123", postId: "456", seeLz: true, forumId: "31", forumName: $0)
    }
    try expect(Set(identities.map(\.signature)).count == identities.count, "canonical names stay distinct")
    for route in identities {
      try expect(TiebaRouteTable.parse(path: route.signature) == route, "lossless route for \(route.signature)")
    }

    let origin: [String: Any] = ["tid": "234", "fid": "32", "fname": "旧吧"]
    let orphan = TiebaViewModelMapper.mapProtoThread(
      ["id": "456", "post_id": "456", "origin_thread_info": origin, "forumInfo": nested]
    )
    let quoted = TiebaRoute.thread(id: "234", forumId: "32", forumName: "旧吧")
    try expect(TiebaThreadCardTarget.card(orphan)?.route() == quoted, "origin keeps its own coordinates")
    try expect(TiebaThreadCardTarget.quoted(orphan)?.route() == quoted, "quoted tap")
    let share = TiebaViewModelMapper.mapProtoThread(
      ["id": "123", "post_id": "456", "is_share_thread": 1, "origin_thread_info": origin, "forumInfo": nested]
    )
    try expect(TiebaThreadCardTarget.card(share)?.route() == history, "share tap keeps outer topic")
    try expect(TiebaThreadCardTarget.quoted(share)?.route() == quoted, "share quote opens origin")
    try expect(TiebaThreadCardTarget.card(["id": "456", "postId": "456"]) == nil, "no reply ID as topic")
    try expect(TiebaThreadCardTarget.card(["id": "0", "threadId": ""]) == nil, "invalid topic")
    let invalidIDs: [Any] = [false, "", "0", "-1", "１２３", "9223372036854775808", 4.5]
    for bad in invalidIDs {
      try expect(TiebaRoutePath.positiveID(bad) == nil, "invalid ID \(bad)")
    }

    let shareURL = "https://tieba.baidu.com/p/123?pid=%34%35%36&see_lz=1"
    let shared = TiebaRoute.thread(id: "123", postId: "456", seeLz: true)
    let nav = TiebaNavigator.shared
    let opened = nav.open(url: URL(string: shareURL)!)
    try expect(opened && nav.capturedRoute == shared, "system share link anchor")
    try expect(TiebaLinkOpener.inAppRoute(shareURL) == shared, "body share link anchor")
    try expect(TiebaLinkOpener.inAppRoute("https://tieba.baidu.com/p/123?pid=%2534") == .thread(id: "123"), "one decode")
  }

  static func response(id: Int64 = 123, pid: UInt64 = 789, deleted: Bool = false) throws -> Data {
    var reply = Tieba_PbPage_PbPageResponse()
    reply.data.thread.id = id
    reply.data.thread.forumName = "yy小说吧"
    reply.data.forum.id = 31
    reply.data.page.currentPage = 1
    reply.data.thread.isDeleted = deleted ? 1 : 0
    var post = Tieba_Post()
    post.id = pid
    post.floor = pid == 789 ? 1 : 2
    reply.data.postList = [post]
    return try reply.serializedData()
  }

  static func business(_ code: Int32, _ message: String) throws -> Data {
    var reply = Tieba_PbPage_PbPageResponse()
    reply.error.errorCode = code
    reply.error.errorMsg = message
    return try reply.serializedData()
  }

  static func load(_ id: String = "123", post: String? = nil, forum: String? = nil) async throws -> TiebaThreadPage {
    try await TiebaThreadAPI.page(
      threadId: id, page: 1, postId: post, seeLz: false, sort: .hot,
      forumId: forum, preferCache: false, allowStaleOnError: false
    )
  }

  static func expectPageError(_ expected: TiebaThreadPageError, id: String = "123", post: String? = nil) async throws {
    do {
      _ = try await load(id, post: post)
      throw FixtureFailure("Expected \(expected)")
    } catch let error as TiebaThreadPageError {
      try expect(error == expected, "expected \(expected), got \(error)")
    }
  }

  static func pageRequestAndErrors() async throws {
    let transport = PageTransport.shared
    let main = try response()
    let anchor = try response(pid: 456)
    await transport.arrange([.success(main), .success(main), .success(anchor)])
    _ = try await load()
    _ = try await load(forum: "0")
    let page = try await load(post: "456", forum: "31")
    try expect(page.thread?.forumName == "yy小说吧" && page.thread?.forumId == "31", "canonical server forum")
    try expect(page.posts.map(\.id) == ["456"], "requested floor")
    var requests = try await transport.pageRequests()
    try expect(requests.count == 3, "three reads")
    try expect(requests.prefix(2).allSatisfy { $0.kz == 123 && !$0.hasForumID && !$0.hasPid && $0.pn == 1 }, "unknown and zero forum omitted")
    let positioned = requests[2]
    try expect(positioned.kz == 123 && positioned.pid == 456 && positioned.forumID == 31, "wire coordinates")
    try expect(positioned.pn == 0, "anchored request decodes with default pn=0")

    await transport.arrange([.success(try business(1989002, "加载数据失败")), .success(main)])
    let fallback = try await load(post: "456", forum: "31")
    requests = try await transport.pageRequests()
    try expect(fallback.posts.map(\.id) == ["789"], "bad floor degrades to topic")
    try expect(requests.count == 2 && requests[0].hasPid && !requests[1].hasPid, "only one unanchored fallback")
    try expect(requests.allSatisfy { $0.kz == 123 && $0.forumID == 31 }, "fallback keeps forum and topic")

    await transport.arrange([.success(main), .success(main)])
    _ = try await load(post: "456")
    requests = try await transport.pageRequests()
    try expect(requests.count == 2, "valid response with missing anchor falls back")

    await transport.arrange([.success(main), .failure(.httpStatus(500)), .failure(.httpStatus(500))])
    _ = try await load()
    let cached = try await TiebaThreadAPI.page(
      threadId: "123", page: 1, postId: nil, seeLz: false, sort: .hot, forumId: "31"
    )
    try expect(cached.thread?.id == "123", "ordinary page cache shared across entry routes")
    let stale = try await TiebaThreadAPI.page(
      threadId: "123", page: 1, postId: nil, seeLz: false, sort: .hot,
      forumId: "31", preferCache: false
    )
    try expect(stale.thread?.id == "123", "read-only HTTP 500 can use cached data")
    do {
      _ = try await load()
      throw FixtureFailure("Feature 01 refresh must surface the failed request")
    } catch TiebaClientError.httpStatus(500) {}

    await transport.arrange([])
    for id in ["", "0", "bad", "9223372036854775808"] {
      try await expectPageError(.invalidThreadID, id: id)
    }
    requests = try await transport.pageRequests()
    try expect(requests.isEmpty, "invalid topic sends nothing")

    await transport.arrange([.failure(.httpStatus(500))])
    do {
      _ = try await load(post: "456")
      throw FixtureFailure("Expected HTTP 500")
    } catch TiebaClientError.httpStatus(500) {}
    requests = try await transport.pageRequests()
    try expect(requests.count == 1, "HTTP error does not degrade to unanchored read")

    await transport.arrange([
      .success(try business(110001, "请登录")), .success(Data([0x0A, 0x7F])), .success(Data()),
      .success(Data("{\"data\":{}}".utf8)),
      .success(try response(id: 999)), .success(try response(deleted: true)),
      .success(try business(4, "帖子可能已被删除")),
    ])
    try await expectPageError(.business(110001, "请登录"), post: "456")
    try await expectPageError(.invalidProtobuf)
    try await expectPageError(.missingData)
    try await expectPageError(.unexpectedJSON)
    try await expectPageError(.unexpectedThread)
    try await expectPageError(.deleted)
    try await expectPageError(.business(4, "帖子可能已被删除"))
    try expect(TiebaThreadPageError.business(4, "").localizedDescription.contains("业务码 4"), "keep code")
    try expect(!TiebaThreadPageError.business(4, "").localizedDescription.contains("已被删除"), "uncertain deletion")
    try expect(TiebaThreadPageError.deleted.localizedDescription.contains("已被删除"), "explicit deletion flag")
  }
}
