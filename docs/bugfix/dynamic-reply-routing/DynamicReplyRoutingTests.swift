import Foundation
import SwiftProtobuf
import TiebaNativeProto

@main
struct DynamicReplyRoutingTests {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure(message) }
  }

  static func feedRow(_ thread: Tieba_ThreadInfo) throws -> [String: Any] {
    var response = Tieba_PersonalizedResponse()
    response.data.threadList = [thread]
    let wire = try response.serializedData()
    let decoded = try TiebaSwiftProto.decode(messagePath: "tieba.personalized.PersonalizedResponse", bytes: wire)
    let mapped = TiebaViewModelMapper.mapResponse(mapper: "feedThreadList", decoded: decoded, options: [:])
    guard let row = (mapped as? [[String: Any]])?.first?["threadInfo"] as? [String: Any] else {
      throw FixtureFailure("Expected a mapped ThreadInfo")
    }
    return row
  }

  static func pageData(kz: Int64, pid: Int64?) throws -> Data {
    var response = Tieba_PbPage_PbPageResponse()
    response.data.thread.id = kz
    var post = Tieba_Post()
    post.id = UInt64(pid ?? 999)
    post.floor = pid == nil ? 1 : 2
    response.data.postList = [post]
    return try response.serializedData()
  }

  static func open(_ route: TiebaRoute) async throws {
    guard case .thread(let kz, let pid, let seeLz, _, let fid, _) = route else {
      throw FixtureFailure("Expected thread route")
    }
    _ = try await TiebaThreadAPI.page(
      threadId: kz, page: 1, postId: pid, seeLz: seeLz, sort: .hot, forumId: fid,
      preferCache: false, allowStaleOnError: false
    )
  }

  static func verify(
    _ target: TiebaThreadCardTarget?, kind: TiebaThreadCardTarget.Kind, kz: Int64, pid: Int64?,
    fid: Int64?, name: String?
  ) async throws {
    guard let target else { throw FixtureFailure("Missing target for \(kz)") }
    let expected = TiebaRoute.thread(
      id: String(kz), postId: pid.map { String($0) }, forumId: fid.map { String($0) }, forumName: name
    )
    let route = target.route()
    try expect(target.kind == kind && route == expected, "Wrong target: \(route.signature)")
    try expect(TiebaRouteTable.parse(path: route.signature) == expected, "Route round trip")
    await PageTransport.shared.arrange([.success(try pageData(kz: kz, pid: pid))])
    try await open(route)
    let requests = try await PageTransport.shared.pageRequests()
    try expect(requests.count == 1, "One pb/page read")
    let request = requests[0]
    try expect(request.kz == kz, "Wire KZ")
    try expect(request.hasPid == (pid != nil) && request.pid == (pid ?? 0), "Wire PID presence and value")
    try expect(request.hasForumID == (fid != nil) && request.forumID == (fid ?? 0), "Wire FID presence and value")
    try expect(request.pn == (pid == nil ? 1 : 0), "Wire pn")
  }

  static func main() async throws {
    guard CommandLine.arguments.count == 2 else { throw FixtureFailure("Pass the descriptor file path") }
    let descriptors = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    try TiebaProtoRegistry.shared.initialize(json: descriptors)

    let topicName = "yy小说吧"
    let special = "测试 A&B#50%/字面%2F吧"
    var topic = Tieba_ThreadInfo()
    topic.id = 123
    topic.threadID = 123
    topic.forumID = 31
    topic.forumName = topicName
    topic.title = "回复：作为普通主帖标题"
    try await verify(TiebaThreadCardTarget.card(try feedRow(topic)), kind: .topic, kz: 123, pid: nil, fid: 31, name: topicName)
    topic.firstPostID = 789
    topic.postID = 789
    try await verify(TiebaThreadCardTarget.card(try feedRow(topic)), kind: .topic, kz: 123, pid: nil, fid: 31, name: topicName)

    var reply = topic
    reply.id = 456
    reply.postID = 456
    reply.forumName = special
    // Real wire tag 52 is post_id. The production decoder normalizes it to postId.
    let mappedReply = try feedRow(reply)
    try expect(mappedReply["postId"] as? String == "456", "normalized tag 52")
    try await verify(TiebaThreadCardTarget.card(mappedReply), kind: .reply, kz: 123, pid: 456, fid: 31, name: special)
    let aliasReply = TiebaViewModelMapper.mapProtoThread([
      "id": "456", "threadId": "0", "thread_id": "123", "post_id": "456", "first_post_id": "789",
      "forum_id": "31", "forum_name": special,
    ])
    try await verify(TiebaThreadCardTarget.card(aliasReply), kind: .reply, kz: 123, pid: 456, fid: 31, name: special)

    var orphan = reply
    orphan.threadID = 0
    let orphanRow = try feedRow(orphan)
    try expect(TiebaThreadCardTarget.card(orphanRow) == nil, "PID cannot become KZ")
    orphan.postID = 0
    let bare = try feedRow(orphan)
    try expect(TiebaThreadCardTarget.card(bare) == nil, "Old mixed row has no reliable topic")
    orphan.threadID = 456
    orphan.postID = 456
    let pidDisguisedAsTopic = try feedRow(orphan)
    try expect(TiebaThreadCardTarget.card(pidDisguisedAsTopic) == nil, "A repeated PID does not establish KZ")

    orphan.originThreadInfo.tid = "123"
    orphan.originThreadInfo.pid = 456
    orphan.originThreadInfo.fid = 32
    orphan.originThreadInfo.fname = topicName
    orphan.threadID = 0
    orphan.postID = 0
    try await verify(TiebaThreadCardTarget.card(try feedRow(orphan)), kind: .reply, kz: 123, pid: 456, fid: 32, name: topicName)
    orphan.threadID = 456
    orphan.postID = 456
    try await verify(TiebaThreadCardTarget.card(try feedRow(orphan)), kind: .reply, kz: 123, pid: 456, fid: 32, name: topicName)
    orphan.threadID = 111
    let conflict = try feedRow(orphan)
    try expect(TiebaThreadCardTarget.card(conflict) == nil, "Two different KZ candidates for same known PID")

    var reference = reply
    reference.isShareThread = 1
    reference.originThreadInfo.tid = "234"
    reference.originThreadInfo.pid = 321
    reference.originThreadInfo.fid = 32
    reference.originThreadInfo.fname = topicName
    try await verify(TiebaThreadCardTarget.card(try feedRow(reference)), kind: .reference, kz: 234, pid: nil, fid: 32, name: topicName)
    reference.isShareThread = 0
    let differentOrigin = try feedRow(reference)
    try await verify(TiebaThreadCardTarget.card(differentOrigin), kind: .reply, kz: 123, pid: 456, fid: 31, name: special)
    try await verify(TiebaThreadCardTarget.quoted(differentOrigin), kind: .reference, kz: 234, pid: nil, fid: 32, name: topicName)

    let nestedAlias = TiebaViewModelMapper.mapProtoThread([
      "id": "456", "post_id": "456", "originThreadInfo": ["tid": "0"],
      "origin_thread_info": ["tid": "123", "pid": "456", "fid": "31", "fname": topicName],
    ])
    try await verify(TiebaThreadCardTarget.card(nestedAlias), kind: .reply, kz: 123, pid: 456, fid: 31, name: topicName)

    var missingForum = reply
    missingForum.forumID = 0
    try await verify(TiebaThreadCardTarget.card(try feedRow(missingForum)), kind: .reply, kz: 123, pid: 456, fid: nil, name: special)
    var mismatchedForum = reply
    mismatchedForum.forumInfo.id = 32
    try await verify(TiebaThreadCardTarget.card(try feedRow(mismatchedForum)), kind: .reply, kz: 123, pid: 456, fid: nil, name: special)
    mismatchedForum.originThreadInfo.tid = "123"
    mismatchedForum.originThreadInfo.fid = 32
    mismatchedForum.originThreadInfo.fname = topicName
    try await verify(TiebaThreadCardTarget.card(try feedRow(mismatchedForum)), kind: .reply, kz: 123, pid: 456, fid: 32, name: topicName)

    var legacy = topic
    legacy.threadID = 0
    try await verify(TiebaThreadCardTarget.card(try feedRow(legacy)), kind: .topic, kz: 123, pid: nil, fid: 31, name: topicName)
    legacy.firstPostID = 0
    legacy.postID = 0
    try await verify(
      TiebaThreadCardTarget.card(try feedRow(legacy), allowLegacyTopicID: true),
      kind: .topic, kz: 123, pid: nil, fid: 31, name: topicName
    )

    await PageTransport.shared.arrange([])
    for bad in ["", "0", "-1", "not-an-id", "9223372036854775808"] {
      try expect(TiebaThreadCardTarget.explicit(threadId: bad, postId: "456") == nil, "Invalid KZ blocked")
      do {
        try await open(.thread(id: bad, postId: "456"))
        throw FixtureFailure("Invalid KZ unexpectedly opened")
      } catch TiebaThreadPageError.invalidThreadID {}
    }
    let invalidRequests = try await PageTransport.shared.pageRequests()
    try expect(invalidRequests.isEmpty, "No request for invalid KZ")

    var rejected = Tieba_PbPage_PbPageResponse()
    rejected.error.errorCode = 4
    await PageTransport.shared.arrange([.success(try rejected.serializedData())])
    do {
      try await open(.thread(id: "123", postId: "456"))
      throw FixtureFailure("Expected business code 4")
    } catch TiebaThreadPageError.business(4, _) {}
    let rejectedRequests = try await PageTransport.shared.pageRequests()
    try expect(rejectedRequests.count == 1, "Code 4 must not re-request the same KZ")

    let presence = TiebaReplyRoutingDiagnostics.rawPresence([
      "thread_id": "123", "post_id": "456", "Cookie": "SYNTHETIC_SECRET", "title": "SYNTHETIC_CONTENT",
    ])
    try expect(presence.contains("thread_id") && presence.contains("post_id"), "Explicit field presence")
    try expect(!presence.contains("SYNTHETIC") && !presence.contains("Cookie") && !presence.contains("title"), "Allowlisted diagnostics")
    print("PASS: recommendation wire -> mapper -> route -> production pb/page request (KZ/PID/FID)")
  }
}
