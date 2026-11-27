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
    return try feedRow(response.serializedData())
  }

  static func feedRow(_ wire: Data) throws -> [String: Any] {
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

  static func open(_ route: TiebaRoute, page: Int = 1, requiresExactReply: Bool = false) async throws {
    guard case .thread(let kz, let pid, let seeLz, _, let fid, _) = route else {
      throw FixtureFailure("Expected thread route")
    }
    _ = try await TiebaThreadAPI.page(
      threadId: kz, page: page, postId: page == 1 ? pid : nil, seeLz: seeLz, sort: .hot, forumId: fid,
      preferCache: false, allowStaleOnError: false, requiresExactReply: requiresExactReply
    )
  }

  static func verifyRefreshAndPagination(_ target: TiebaThreadCardTarget?, reply: Bool) async throws {
    guard let target else { throw FixtureFailure("Missing target for refresh and pagination") }
    let route = target.route()
    let firstPage = try pageData(kz: 123, pid: reply ? 456 : nil)
    let nextPage = try pageData(kz: 123, pid: nil)
    await PageTransport.shared.arrange([.success(firstPage), .success(firstPage), .success(nextPage)])
    try await open(route)
    try await open(route)
    try await open(route, page: 2)
    let requests = try await PageTransport.shared.pageRequests()
    try expect(requests.count == 3, "First load, refresh and pagination")
    try expect(requests.allSatisfy { $0.kz == 123 && $0.hasForumID && $0.forumID == 31 }, "Same KZ and FID throughout")
    try expect(requests.map(\.pn) == (reply ? [0, 0, 2] : [1, 1, 2]), "Refresh keeps locator mode; pagination uses page number")
    try expect(requests.map(\.hasPid) == [reply, reply, false], "Pagination drops PID; refresh retains it")
    try expect(requests.map(\.pid) == (reply ? [456, 456, 0] : [0, 0, 0]), "Wire PID sequence")
  }

  static func verify(
    _ target: TiebaThreadCardTarget?, kind: TiebaThreadCardTarget.Kind, kz: Int64, pid: Int64?,
    fid: Int64?, name: String?, requiresExactReply: Bool = false
  ) async throws {
    guard let target else { throw FixtureFailure("Missing target for \(kz)") }
    let expected = TiebaRoute.thread(
      id: String(kz), postId: pid.map { String($0) }, forumId: fid.map { String($0) }, forumName: name
    )
    let route = target.route()
    try expect(target.kind == kind && route == expected, "Wrong target: \(route.signature)")
    try expect(TiebaRouteTable.parse(path: route.signature) == expected, "Route round trip")
    await PageTransport.shared.arrange([.success(try pageData(kz: kz, pid: pid))])
    try await open(route, requiresExactReply: requiresExactReply)
    let requests = try await PageTransport.shared.pageRequests()
    try expect(requests.count == 1, "One pb/page read")
    let request = requests[0]
    try expect(request.kz == kz, "Wire KZ")
    try expect(request.hasPid == (pid != nil) && request.pid == (pid ?? 0), "Wire PID presence and value")
    try expect(request.hasForumID == (fid != nil) && request.forumID == (fid ?? 0), "Wire FID presence and value")
    try expect(request.pn == (pid == nil ? 1 : 0), "Wire pn")
  }

  static func verifyPersonalizedReply() async throws {
    // Reconstruct a packet from the real mapped fields. The original wire
    // presence is unknown, so this is a fixture, not a captured response.
    let cardID: Int64 = 2_100_000_009_798_432
    let threadID: Int64 = 11_230_786_026
    let postID: Int64 = 154_184_058_416
    let forumID: Int64 = 1_937_070
    var thread = Tieba_ThreadInfo()
    thread.id = cardID
    thread.threadID = cardID
    thread.postID = postID
    thread.forumID = forumID
    thread.originThreadInfo.tid = String(threadID)
    let row = try feedRow(thread)
    try expect(row["id"] as? String == String(cardID) && row["threadId"] as? String == String(cardID), "Mapper keeps both outer IDs")
    let opening = TiebaThreadCardTarget.opening(row, personalized: true)
    try expect(opening.rule == .personalizedOrigin, "Verify personalized origin before navigation")
    try await verify(opening.target, kind: .reply, kz: threadID, pid: postID, fid: nil, name: nil, requiresExactReply: true)
    try await verifyReplyHandoff(opening.target, kz: threadID, pid: postID)
    try await verify(
      TiebaThreadCardTarget.opening(row, personalized: false).target,
      kind: .reply, kz: cardID, pid: postID, fid: forumID, name: nil
    )
    try await verify(
      TiebaThreadCardTarget.opening(row, personalized: true, reference: true).target,
      kind: .reference, kz: threadID, pid: nil, fid: nil, name: nil
    )

    thread.originThreadInfo.fid = 42
    let withOriginForum = try feedRow(thread)
    try await verify(
      TiebaThreadCardTarget.opening(withOriginForum, personalized: true).target,
      kind: .reply, kz: threadID, pid: postID, fid: 42, name: nil, requiresExactReply: true
    )

    var invalidOrigin = thread
    invalidOrigin.originThreadInfo.tid = ""
    let noOriginID = try feedRow(invalidOrigin)
    let unresolved = TiebaThreadCardTarget.opening(noOriginID, personalized: true)
    try expect(unresolved.rule == .invalidPersonalizedOrigin && unresolved.target == nil, "Missing origin KZ cannot use outer card ID")
    invalidOrigin.originThreadInfo.tid = String(postID)
    let originRepeatsPID = try feedRow(invalidOrigin)
    try expect(TiebaThreadCardTarget.opening(originRepeatsPID, personalized: true).target == nil, "Origin KZ cannot be PID")

    var noAnchor = thread
    noAnchor.postID = 0
    let noPost = try feedRow(noAnchor)
    let legacyReference = TiebaThreadCardTarget.opening(noPost, personalized: true)
    try expect(legacyReference.rule == .standardCard, "Without a PID there is no personalized reply to verify")
    try await verify(legacyReference.target, kind: .reference, kz: threadID, pid: nil, fid: 42, name: nil)

    var share = thread
    share.isShareThread = 1
    let shared = try feedRow(share)
    try await verify(
      TiebaThreadCardTarget.opening(shared, personalized: true).target,
      kind: .reference, kz: threadID, pid: nil, fid: 42, name: nil
    )

    var ordinary = thread
    ordinary.id = threadID
    ordinary.threadID = threadID
    ordinary.firstPostID = 789
    ordinary.originThreadInfo.tid = "321"
    let ordinaryRow = try feedRow(ordinary)
    let ordinaryOpening = TiebaThreadCardTarget.opening(ordinaryRow, personalized: true)
    try expect(ordinaryOpening.rule == .standardCard, "Ordinary reply keeps its own thread beside an unrelated quote")
    try await verify(ordinaryOpening.target, kind: .reply, kz: threadID, pid: postID, fid: forumID, name: nil)

    var sameID = thread
    sameID.id = threadID
    sameID.threadID = threadID
    sameID.originThreadInfo.fid = 0
    let coincidentIDs = try feedRow(sameID)
    try await verify(
      TiebaThreadCardTarget.opening(coincidentIDs, personalized: true).target,
      kind: .reply, kz: threadID, pid: postID, fid: nil, name: nil, requiresExactReply: true
    )

    guard let route = opening.target?.route() else { throw FixtureFailure("Missing origin candidate") }
    try await rejectUnverifiedReply(route, response: pageData(kz: threadID, pid: nil), error: .missingAnchor)
    try await rejectUnverifiedReply(route, response: pageData(kz: 321, pid: postID), error: .unexpectedThread)
    try await rejectUnverifiedReply(route, response: pageData(kz: 0, pid: postID), error: .unexpectedThread)
    try await verifyAmbiguousOuterReplies(template: thread, kz: threadID, pid: postID)

    TiebaReplyRoutingDiagnostics.enabled = true
    defer { TiebaReplyRoutingDiagnostics.enabled = false }
    let debugRow = try feedRow(sameID)
    let raw = debugRow[TiebaReplyRoutingDiagnostics.presenceKey] as? String ?? ""
    try expect(raw.contains("post_id#52=present") && raw.contains("firstPostId#40=absent"), "Capture presence from wire tags")
    try expect(raw.contains("wire OriginThreadInfo: tid#5=present fid#7=absent pid#25=absent"), "Capture absent origin FID and PID on wire")
    // PersonalizedResponse.data#2 > thread_list#2 > id#1=123, post_id#52=0.
    let explicitZero = try feedRow(Data([0x12, 0x07, 0x12, 0x05, 0x08, 0x7b, 0xa0, 0x03, 0x00]))
    let zeroRaw = explicitZero[TiebaReplyRoutingDiagnostics.presenceKey] as? String ?? ""
    try expect(
      zeroRaw.contains("post_id#52=present") && explicitZero["postId"] as? String == "",
      "Wire presence survives proto3 dropping an explicit zero"
    )
    guard let tap = TiebaReplyRoutingDiagnostics.card(
      debugRow, target: opening.target, source: .personalized, rule: opening.rule
    ) else { throw FixtureFailure("Expected personalized reply diagnostics") }
    TiebaReplyRoutingDiagnostics.PageAttempt(tap).saveFailure(verifyingReply: true)
    let report = TiebaReplyRoutingDiagnostics.latestFailure ?? ""
    try expect(
      report.contains("kz=OriginThreadInfo.tid#5") && report.contains("pid=ThreadInfo.post_id#52")
        && report.contains("fid=omitted no trusted origin FID"),
      "Diagnostic identifies every coordinate source"
    )
  }

  static func verifyAmbiguousOuterReplies(template: Tieba_ThreadInfo, kz: Int64, pid: Int64) async throws {
    var rejected = Tieba_PbPage_PbPageResponse()
    rejected.error.errorCode = 4
    let codeFour = try rejected.serializedData()

    var missingOrigin = template
    missingOrigin.clearOriginThreadInfo()
    let missingOriginRow = try feedRow(missingOrigin)
    let unknown = TiebaThreadCardTarget.opening(missingOriginRow, personalized: true)
    try expect(unknown.rule == .personalizedOuter(.missingOrigin) && unknown.rule.requiresExactReply, "No origin requires proof of outer KZ")
    guard let unknownRoute = unknown.target?.route() else { throw FixtureFailure("Missing outer candidate") }
    try await rejectUnverifiedReply(unknownRoute, response: codeFour, error: .business(4, ""))

    // The same shape can be an ordinary reply with a valid outer KZ.
    var ordinary = missingOrigin
    ordinary.id = kz
    ordinary.threadID = kz
    let ordinaryRow = try feedRow(ordinary)
    let ordinaryOpening = TiebaThreadCardTarget.opening(ordinaryRow, personalized: true)
    try expect(ordinaryOpening.rule.requiresExactReply, "Unqualified equality is not proof either way")
    try await verify(ordinaryOpening.target, kind: .reply, kz: kz, pid: pid, fid: nil, name: nil, requiresExactReply: true)

    var conflict = template
    conflict.originThreadInfo.pid = 789
    let conflictRow = try feedRow(conflict)
    let conflictingOpening = TiebaThreadCardTarget.opening(conflictRow, personalized: true)
    try expect(
      conflictingOpening.rule == .personalizedOuter(.differentOriginPID) && conflictingOpening.rule.requiresExactReply,
      "Conflicting origin PID cannot trigger direct navigation"
    )
    guard let conflictingRoute = conflictingOpening.target?.route() else { throw FixtureFailure("Missing conflict candidate") }
    try await rejectUnverifiedReply(conflictingRoute, response: codeFour, error: .business(4, ""))

    conflict.originThreadInfo.tid = "321"
    conflict.id = kz
    conflict.threadID = kz
    let unrelatedQuoteRow = try feedRow(conflict)
    let unrelatedQuote = TiebaThreadCardTarget.opening(unrelatedQuoteRow, personalized: true)
    try await verify(unrelatedQuote.target, kind: .reply, kz: kz, pid: pid, fid: nil, name: nil, requiresExactReply: true)
    try await verify(
      TiebaThreadCardTarget.opening(unrelatedQuoteRow, personalized: true, reference: true).target,
      kind: .reference, kz: 321, pid: nil, fid: 42, name: nil
    )

    missingOrigin.id = pid
    missingOrigin.threadID = pid
    let pidAsTopic = try feedRow(missingOrigin)
    let invalid = TiebaThreadCardTarget.opening(pidAsTopic, personalized: true)
    try expect(invalid.rule == .invalidPersonalizedOuter && invalid.target == nil, "Reject a candidate equal to the target PID")
  }

  static func verifyReplyHandoff(_ target: TiebaThreadCardTarget?, kz: Int64, pid: Int64) async throws {
    guard let target else { throw FixtureFailure("Missing verified-reply target") }
    let firstPage = try pageData(kz: kz, pid: pid)
    let nextPage = try pageData(kz: kz, pid: nil)
    await PageTransport.shared.arrange([.success(firstPage), .success(firstPage), .success(nextPage)])
    let verified = try await TiebaThreadAPI.verifyReply(
      threadId: target.threadId, postId: target.postId, forumId: target.forumId, sort: .hot, accountKey: "synthetic"
    )
    let received = TiebaThreadAPI.$openingReplyPage.withValue(verified) { TiebaThreadAPI.openingReplyPage }
    try expect(received?.matches(
      threadId: String(kz), postId: String(pid), accountKey: "synthetic", sort: .hot, seeLz: false
    ) == true, "First load can render the verified page directly")
    try expect(received?.page.posts.contains { $0.id == String(pid) } == true, "Handed-off page contains the scroll anchor")
    try expect(received?.matches(
      threadId: String(kz), postId: String(pid), accountKey: "another-account", sort: .hot, seeLz: false
    ) == false, "A different account cannot consume the handoff")
    try expect(TiebaThreadAPI.openingReplyPage == nil, "Handoff cannot leak into later navigation")
    let initial = try await PageTransport.shared.pageRequests()
    try expect(initial.count == 1, "Verification and first render use one request")

    try await open(target.route())
    try await open(target.route(), page: 2)
    let requests = try await PageTransport.shared.pageRequests()
    try expect(requests.map(\.kz) == [kz, kz, kz], "Refresh and pagination retain the verified KZ")
    try expect(requests.map(\.pid) == [pid, pid, 0] && requests.map(\.pn) == [0, 0, 2], "Refresh keeps PID; pagination drops it")
    try expect(requests.map(\.hasPid) == [true, true, false] && requests.allSatisfy { !$0.hasForumID }, "Wire field presence")
  }

  static func verifyNavigationOwnership() throws {
    var gate = TiebaThreadCardTarget.VerificationGate()
    let older = gate.begin(accountKey: "a")
    let newer = gate.begin(accountKey: "a")
    let oldFinish = gate.finish(older, accountKey: "a", invalidated: false, isVisible: true)
    let newFinish = gate.finish(newer, accountKey: "a", invalidated: false, isVisible: true)
    let duplicate = gate.finish(newer, accountKey: "a", invalidated: false, isVisible: true)
    try expect(oldFinish == nil && newFinish == true && duplicate == nil, "Only the latest tap may navigate once")

    let leaving = gate.begin(accountKey: "a")
    let hidden = gate.finish(leaving, accountKey: "a", invalidated: false, isVisible: false)
    try expect(hidden == false, "A hidden segment cannot navigate")
    let refreshing = gate.begin(accountKey: "a")
    gate.cancel()
    let invalidated = gate.finish(refreshing, accountKey: "a", invalidated: false, isVisible: true)
    try expect(invalidated == nil, "Refresh or departure invalidates the outstanding tap")
    let startedOnA = gate.begin(accountKey: "a")
    let switched = gate.finish(startedOnA, accountKey: "b", invalidated: false, isVisible: true)
    try expect(switched == false, "Different account rejects a late result")
    let startedBeforeSwitch = gate.begin(accountKey: "a")
    let switchedBack = gate.finish(startedBeforeSwitch, accountKey: "a", invalidated: true, isVisible: true)
    try expect(switchedBack == false, "A session change invalidates the result even if the account switched back")
  }

  static func rejectUnverifiedReply(
    _ route: TiebaRoute, response: Data, error expected: TiebaThreadPageError
  ) async throws {
    guard case .thread(let kz, let pid, _, _, let fid, _) = route else {
      throw FixtureFailure("Missing verification coordinates")
    }
    await PageTransport.shared.arrange([.success(response)])
    do {
      _ = try await TiebaThreadAPI.verifyReply(threadId: kz, postId: pid, forumId: fid, sort: .hot, accountKey: "synthetic")
      throw FixtureFailure("Unconfirmed personalized reply opened")
    } catch let failure as TiebaThreadPageError {
      try expect(failure == expected, "Reject unverified navigation")
    }
    let requests = try await PageTransport.shared.pageRequests()
    try expect(requests.count == 1 && requests[0].hasPid, "Verification cannot retry without the anchor")
  }

  static func main() async throws {
    guard CommandLine.arguments.count == 2 else { throw FixtureFailure("Pass the descriptor file path") }
    let descriptors = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    try TiebaProtoRegistry.shared.initialize(json: descriptors)
    try verifyNavigationOwnership()
    try await verifyPersonalizedReply()

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
    let topicTarget = TiebaThreadCardTarget.card(try feedRow(topic))
    try await verify(topicTarget, kind: .topic, kz: 123, pid: nil, fid: 31, name: topicName)
    try await verifyRefreshAndPagination(topicTarget, reply: false)

    var reply = topic
    reply.id = 456
    reply.postID = 456
    reply.forumName = special
    // Real wire tag 52 is post_id. The production decoder normalizes it to postId.
    let mappedReply = try feedRow(reply)
    try expect(mappedReply["postId"] as? String == "456", "normalized tag 52")
    let replyTarget = TiebaThreadCardTarget.card(mappedReply)
    try await verify(replyTarget, kind: .reply, kz: 123, pid: 456, fid: 31, name: special)
    try await verifyRefreshAndPagination(replyTarget, reply: true)
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

    // Synthetic wire fixtures. These exercise the separate first-floor PID,
    // without making any claim about the fields of the failing device card.
    var firstFloorAsTopic = reply
    firstFloorAsTopic.threadID = 789
    let badTopLevel = try feedRow(firstFloorAsTopic)
    try expect(TiebaThreadCardTarget.card(badTopLevel) == nil, "Known first-floor PID cannot establish a reply KZ")
    firstFloorAsTopic.threadID = 0
    firstFloorAsTopic.originThreadInfo.tid = "789"
    firstFloorAsTopic.originThreadInfo.pid = 456
    let badNested = try feedRow(firstFloorAsTopic)
    try expect(TiebaThreadCardTarget.card(badNested) == nil, "Matching nested PID does not make first-floor PID a KZ")
    firstFloorAsTopic.postID = 0
    let invalidNestedKZ = try feedRow(firstFloorAsTopic)
    try expect(TiebaThreadCardTarget.card(invalidNestedKZ) == nil, "An invalid nested KZ cannot fall back to a reference")
    firstFloorAsTopic.originThreadInfo.tid = "456"
    let repeatedNestedPID = try feedRow(firstFloorAsTopic)
    try expect(TiebaThreadCardTarget.card(repeatedNestedPID) == nil, "Nested repetition of the card PID is not a reference KZ")
    firstFloorAsTopic.originThreadInfo.tid = "789"
    firstFloorAsTopic.postID = 456
    firstFloorAsTopic.threadID = 123
    try await verify(
      TiebaThreadCardTarget.card(try feedRow(firstFloorAsTopic)), kind: .reply, kz: 123, pid: 456, fid: 31, name: special
    )
    firstFloorAsTopic.threadID = 789
    firstFloorAsTopic.originThreadInfo.tid = "123"
    firstFloorAsTopic.originThreadInfo.fid = 31
    firstFloorAsTopic.originThreadInfo.fname = special
    try await verify(
      TiebaThreadCardTarget.card(try feedRow(firstFloorAsTopic)), kind: .reply, kz: 123, pid: 456, fid: 31, name: special
    )

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
    mismatchedForum.forumInfo.id = 31
    try await verify(TiebaThreadCardTarget.card(try feedRow(mismatchedForum)), kind: .reply, kz: 123, pid: 456, fid: nil, name: topicName)

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

    try await verifyDiagnostics(reply: reply, rejected: rejected, orphan: badNested)
    print("PASS: recommendation wire -> mapper -> route -> production pb/page request (KZ/PID/FID)")
  }

  static func verifyDiagnostics(
    reply: Tieba_ThreadInfo, rejected: Tieba_PbPage_PbPageResponse, orphan: [String: Any]
  ) async throws {
    let raw = TiebaReplyRoutingDiagnostics.rawFields([
      "id": "not-a-number", "thread_id": "123", "post_id": "456",
      "origin_thread_info": ["tid": "123", "pid": "456", "fid": "31", "content": "SYNTHETIC_BODY"],
      "forum_info": ["id": "32", "name": "SYNTHETIC_NAME"],
      "Cookie": "SYNTHETIC_SECRET", "title": "SYNTHETIC_CONTENT",
    ], forum: ["id": "33"])
    try expect(raw.contains("id=-") && raw.contains("thread_id=123") && raw.contains("post_id=456"), "Allowlisted raw identifiers")
    try expect(raw.contains("raw.origin_thread_info: tid=123 pid=456 fid=31"), "Nested field presence and values")
    try expect(raw.contains("raw.forum_info: id=32") && raw.contains("raw.containerForum: id=33"), "FID sources")
    try expect(!raw.contains("SYNTHETIC") && !raw.contains("Cookie") && !raw.contains("title"), "Exclude text and credentials")

    TiebaReplyRoutingDiagnostics.enabled = true
    defer { TiebaReplyRoutingDiagnostics.enabled = false }
    _ = TiebaReplyRoutingDiagnostics.card(orphan, target: nil, source: .personalized)
    let unresolved = TiebaReplyRoutingDiagnostics.latestFailure
    try expect(
      unresolved?.contains("result=unresolved request=none network=not-started navigation=not-opened") == true,
      "Record unresolvable card without a request"
    )

    let row = try feedRow(reply)
    var concernThread = reply
    concernThread.postID = 0
    var concern = Tieba_UserLike_ConcernData()
    concern.threadList = concernThread
    concern.postData.id = 654
    var concernResponse = Tieba_UserLike_UserLikeResponse()
    concernResponse.data.threadInfo = [concern]
    let concernDecoded = try TiebaSwiftProto.decode(
      messagePath: "tieba.userLike.UserLikeResponse", bytes: concernResponse.serializedData()
    )
    let concernData = TiebaViewModelMapper.mapResponse(mapper: "userLike", decoded: concernDecoded, options: [:])
    let concernItems = (concernData as? [String: Any])?["items"] as? [[String: Any]]
    guard let concernRow = concernItems?.first?["threadInfo"] as? [String: Any] else {
      throw FixtureFailure("Expected a mapped ConcernData.threadList")
    }
    let concernRaw = concernRow[TiebaReplyRoutingDiagnostics.presenceKey] as? String
    try expect(concernRaw?.contains("raw.concernPost: present=true id=654") == true, "Preserve nested concern post ID for diagnostics")
    try expect(
      TiebaThreadCardTarget.card(concernRow)?.route() == .thread(id: "123", forumId: "31", forumName: reply.forumName),
      "Unverified concern field does not change thread coordinates or create a reply anchor"
    )

    guard let target = TiebaThreadCardTarget.card(row),
          let tap = TiebaReplyRoutingDiagnostics.card(row, target: target, source: .personalized) else {
      throw FixtureFailure("Missing diagnostic tap")
    }
    let attempt = TiebaReplyRoutingDiagnostics.PageAttempt(tap)
    await PageTransport.shared.arrange([.success(try rejected.serializedData())])
    do {
      try await TiebaReplyRoutingDiagnostics.$pageAttempt.withValue(attempt) {
        try await open(target.route())
      }
      throw FixtureFailure("Expected business code 4")
    } catch TiebaThreadPageError.business(4, _) {
      attempt.saveFailure(verifyingReply: true, error: TiebaThreadPageError.business(4, "SYNTHETIC_MESSAGE"))
    }
    let report = TiebaReplyRoutingDiagnostics.latestFailure ?? ""
    try expect(
      report.contains("reason=business-4 network=response-received navigation=not-opened") && !report.contains("SYNTHETIC_MESSAGE"),
      "Diagnose rejected verification without logging server text"
    )
    for line in [
      "tap source=personalized kind=reply", "route: kz=123 pid=456 fid=31",
      "request /c/f/pb/page kz=123 pid=456 fid=31 pn=0",
      "response /c/f/pb/page kz=123 pid=456 fid=31 pn=0 code=4",
    ] {
      try expect(report.contains(line), "Failed attempt includes \(line)")
    }
    try expect(report.contains("raw: ") && report.contains("threadId=123"), "Keep pre-mapper coordinate evidence")
    await PageTransport.shared.arrange([.success(try pageData(kz: 123, pid: 456))])
    try await open(target.route())
    try expect(TiebaReplyRoutingDiagnostics.latestFailure == report, "Unrelated request leaves last failure unchanged")

    TiebaReplyRoutingDiagnostics.enabled = false
    TiebaReplyRoutingDiagnostics.enabled = true
    attempt.saveFailure()
    try expect(TiebaReplyRoutingDiagnostics.latestFailure == nil, "Disabling diagnostics invalidates earlier in-flight attempts")
  }
}
