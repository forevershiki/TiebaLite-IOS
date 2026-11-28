import Foundation
import SwiftProtobuf
import TiebaNativeProto

private actor InteractionTransport {
  struct Call: Sendable {
    let path: String
    let body: String

    var fields: [String: String] {
      var url = URLComponents()
      url.percentEncodedQuery = body
      return Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
  }

  static let shared = InteractionTransport()
  private(set) var calls: [Call] = []
  private var code = 0

  func reset(code: Int = 0) {
    calls = []
    self.code = code
  }

  func send(path: String, body: String) -> Data {
    calls.append(Call(path: path, body: body))
    return Data("{\"error_code\":\(code)}".utf8)
  }
}

// Authentication and network are synthetic. The suite compiles the actual
// action, feedback, signed-form serialization and business-response methods.
enum TiebaSession {
  @TaskLocal static var duringTbs: (@Sendable () -> Void)? = nil

  static func requireTbs() async throws -> String {
    duringTbs?()
    return "fixture"
  }
}

final class TiebaBackgroundSnapshot: Sendable {
  static let shared = TiebaBackgroundSnapshot()
  let uid = ""
  let stoken = ""
  let bduss = ""
}

enum TiebaSigner {
  static func signParams(_ fields: [String: String]) -> String { "fixture" }
}

enum TiebaJSON {
  static func int(_ object: [String: Any]?, _ keys: String...) -> Int? {
    keys.lazy.compactMap { object?[$0] as? Int }.first
  }

  static func string(_ object: [String: Any]?, _ keys: String...) -> String? {
    keys.lazy.compactMap { object?[$0] as? String }.first
  }
}

final class TiebaHttpClient: Sendable {
  struct Response: Sendable {
    let status: Int
    let bodyData: Data
  }

  static let shared = TiebaHttpClient()

  func send(
    urlString: String, method: String, headers: [String: String], body: String,
    formParts: [String], requestId: String, timeoutMs: Int
  ) async throws -> Response {
    guard method == "POST", let url = URL(string: urlString), url.host == "tiebac.baidu.com" else {
      throw FixtureFailure("Unexpected interaction transport")
    }
    return Response(status: 200, bodyData: await InteractionTransport.shared.send(path: url.path, body: body))
  }
}

@main
struct DynamicReplyRoutingTests {
  static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureFailure(message) }
  }

  static func verifyInteractions() async throws {
    let topic = TiebaViewModelMapper.mapProtoThread([
      "id": "901", "threadId": "123", "firstPostId": "789", "forumId": "31",
    ])
    let reply = TiebaViewModelMapper.mapProtoThread([
      "id": "902", "threadId": "123", "firstPostId": "789", "postId": "456", "forumId": "31",
    ])
    let sibling = TiebaViewModelMapper.mapProtoThread([
      "id": "903", "threadId": "123", "firstPostId": "789", "postId": "457", "forumId": "31",
    ])
    let event = TiebaViewModelMapper.mapProtoThread([
      "id": "2100000009798432", "threadId": "2100000009798432", "postId": "154184058416", "forumId": "1937070",
      "originThreadInfo": ["tid": "11230786026"],
    ])
    let repost = TiebaViewModelMapper.mapProtoThread([
      "id": "904", "threadId": "904", "isShareThread": 1, "firstPostId": "905",
      "originThreadInfo": ["tid": "123", "pid": "456"],
    ])
    await PageTransport.shared.arrange([])
    for row in [topic, reply, repost] {
      let opening = TiebaThreadCardTarget.opening(row, personalized: true)
      guard let target = opening.target else { throw FixtureFailure("Missing share target") }
      try expect(
        TiebaThreadCardTarget.shareURL(for: target, verifiedReply: false, opening: opening.rule) == "https://tieba.baidu.com/p/123",
        "S01, S02, S06 use the ordinary or cited thread, never a PID"
      )
    }
    let quote = TiebaThreadCardTarget.opening(repost, personalized: true, reference: true)
    guard let quoteTarget = quote.target else { throw FixtureFailure("Missing explicit reference target") }
    try expect(
      TiebaThreadCardTarget.shareURL(for: quoteTarget, verifiedReply: false, opening: quote.rule) == "https://tieba.baidu.com/p/123",
      "S06 explicit reference uses the cited topic"
    )
    let directReads = try await PageTransport.shared.pageRequests()
    try expect(directReads.isEmpty, "Ordinary and repost share are local decisions")
    let special = TiebaThreadCardTarget.opening(event, personalized: true)
    guard let share = special.target else { throw FixtureFailure("Missing event share candidate") }
    try expect(TiebaThreadCardTarget.shareURL(for: share, verifiedReply: false, opening: special.rule) == nil, "S05 no speculative URL")
    await PageTransport.shared.arrange([.success(try pageData(kz: 11230786026, pid: 154184058416))])
    _ = try await TiebaThreadAPI.verifyReply(
      threadId: share.threadId, postId: share.postId, forumId: share.forumId, sort: .hot, accountKey: "synthetic"
    )
    let shareReads = try await PageTransport.shared.pageRequests()
    try expect(
      shareReads.count == 1 && shareReads[0].kz == 11230786026 && shareReads[0].pid == 154184058416
        && shareReads[0].hasPid && !shareReads[0].hasForumID && shareReads[0].pn == 0,
      "S03/S04 verify the exact origin before creating the link"
    )
    try expect(
      TiebaThreadCardTarget.shareURL(for: share, verifiedReply: true, opening: special.rule) == "https://tieba.baidu.com/p/11230786026",
      "S03 correct origin URL"
    )
    try await rejectUnverifiedReply(
      share.route(), response: pageData(kz: 11230786026, pid: nil), error: .missingAnchor
    )

    await InteractionTransport.shared.reset()
    for row in [event, repost] {
      try expect(TiebaThreadCardTarget.agreeTarget(row, personalized: true) == nil, "L03/L04 unknown card heart target is blocked")
      try expect(TiebaThreadCardTarget.recommendationFeedback(row, personalized: true) == nil, "Feedback identity is unconfirmed")
    }
    let noWrites = await InteractionTransport.shared.calls
    try expect(noWrites.isEmpty, "Ambiguous cards cannot send writes")
    guard let topicTarget = TiebaThreadCardTarget.agreeTarget(topic, personalized: true),
          let replyTarget = TiebaThreadCardTarget.agreeTarget(reply, personalized: true),
          let siblingTarget = TiebaThreadCardTarget.agreeTarget(sibling, personalized: true) else {
      throw FixtureFailure("Missing known thread-level interaction")
    }
    await PageTransport.shared.arrange([])
    _ = try await TiebaThreadActionAPI.setFeedAgree(topicTarget, agree: true, validateSession: {})
    _ = try await TiebaThreadActionAPI.setFeedAgree(topicTarget, agree: false, validateSession: {})
    let topicReads = try await PageTransport.shared.pageRequests()
    try expect(topicReads.isEmpty, "L01 known first floor requires no lookup")
    let topicWrites = await InteractionTransport.shared.calls
    try expect(topicWrites.count == 2 && topicWrites.allSatisfy {
      $0.path == "/c/c/agree/opAgree" && $0.fields["thread_id"] == "123" && $0.fields["post_id"] == "789"
        && $0.fields["obj_type"] == "3" && $0.fields["agree_type"] == "2" && $0.fields["fid"] == nil
    }, "L01/L06 serialized coordinates and object type")
    try expect(topicWrites.map { $0.fields["op_type"] } == ["0", "1"], "L06 agree and unagree share identity")

    var verifiedReply = Tieba_PbPage_PbPageResponse()
    verifiedReply.data.thread.id = 123
    verifiedReply.data.thread.firstPostID = 789
    var post = Tieba_Post()
    post.id = 456
    post.floor = 2
    verifiedReply.data.postList = [post]
    let verifiedBytes = try verifiedReply.serializedData()
    await PageTransport.shared.arrange([.success(verifiedBytes)])
    _ = try await TiebaThreadActionAPI.setFeedAgree(replyTarget, agree: true, validateSession: {})
    let replyWrites = await InteractionTransport.shared.calls
    try expect(replyWrites.count == 3 && replyWrites.last?.fields["post_id"] == "789", "L02 verified ordinary reply card retains the thread heart")
    let replyReads = try await PageTransport.shared.pageRequests()
    try expect(replyReads.count == 1 && replyReads[0].pid == 456 && replyReads[0].pn == 0, "L04 verify distinct reply anchor before writing")
    await PageTransport.shared.arrange([.success(try pageData(kz: 123, pid: nil))])
    do {
      _ = try await TiebaThreadActionAPI.setFeedAgree(replyTarget, agree: true, validateSession: {})
      throw FixtureFailure("Missing reply allowed a write")
    } catch TiebaThreadPageError.missingAnchor {}
    let afterMissing = await InteractionTransport.shared.calls
    try expect(afterMissing.count == 3, "L05 missing PID sends no write")

    var alternateFirst = Tieba_Post()
    alternateFirst.id = 998
    alternateFirst.floor = 1
    verifiedReply.data.postList.append(alternateFirst)
    await PageTransport.shared.arrange([.success(try verifiedReply.serializedData())])
    do {
      _ = try await TiebaThreadActionAPI.setFeedAgree(replyTarget, agree: true, validateSession: {})
      throw FixtureFailure("Conflicting first floors allowed a write")
    } catch TiebaThreadPageError.missingAnchor {}
    let afterConflict = await InteractionTransport.shared.calls
    try expect(afterConflict.count == 3, "L05 a matching reply cannot override conflicting first floors")

    let active = TiebaMutex(true)
    await PageTransport.shared.arrange([.success(verifiedBytes)]) { active.withLock { $0 = false } }
    do {
      _ = try await TiebaThreadActionAPI.setFeedAgree(replyTarget, agree: true) {
        guard active.withLock({ $0 }) else { throw CancellationError() }
      }
      throw FixtureFailure("Account changed during reply lookup but write continued")
    } catch is CancellationError {}
    let invalidatedReads = try await PageTransport.shared.pageRequests()
    let invalidatedWrites = await InteractionTransport.shared.calls
    try expect(invalidatedReads.count == 1 && invalidatedWrites.count == 3, "L10 account change during lookup stops the write")

    let topicWithoutFirst = TiebaViewModelMapper.mapProtoThread(["id": "901", "threadId": "123"])
    guard let lookupTarget = TiebaThreadCardTarget.agreeTarget(topicWithoutFirst, personalized: true) else {
      throw FixtureFailure("Missing topic lookup target")
    }
    await PageTransport.shared.arrange([.success(try pageData(kz: 321, pid: nil))])
    do {
      _ = try await TiebaThreadActionAPI.setFeedAgree(lookupTarget, agree: true, validateSession: {})
      throw FixtureFailure("Mismatched topic provided a first floor")
    } catch TiebaThreadPageError.missingAnchor {}
    let mismatchWrites = await InteractionTransport.shared.calls
    try expect(mismatchWrites.count == 3, "L01 mismatched topic cannot trigger a write")
    await PageTransport.shared.arrange([.success(try pageData(kz: 123, pid: nil))])
    _ = try await TiebaThreadActionAPI.setFeedAgree(lookupTarget, agree: true, validateSession: {})
    let lookupReads = try await PageTransport.shared.pageRequests()
    let lookupWrites = await InteractionTransport.shared.calls
    try expect(
      lookupReads.count == 1 && lookupReads[0].kz == 123 && !lookupReads[0].hasPid && lookupReads[0].pn == 1
        && lookupWrites.count == 4 && lookupWrites.last?.fields["post_id"] == "999",
      "L01 reads only the required first floor if missing from the card"
    )

    try await verifyAgreeState(topic: topicTarget, reply: replyTarget, sibling: siblingTarget)
    guard let feedback = TiebaThreadCardTarget.recommendationFeedback(topic, personalized: true) else {
      throw FixtureFailure("Missing ordinary recommendation feedback")
    }
    try expect(TiebaThreadCardTarget.ForumTarget(event)?.id == "1937070", "F02 local hiding uses the card forum")
    let fullForum = TiebaThreadCardTarget.ForumTarget(["forumId": "1937070", "forumName": "yy小说吧"])
    let nameOnly = TiebaThreadCardTarget.ForumTarget(["forumName": "yy小说吧"])
    let anotherForum = TiebaThreadCardTarget.ForumTarget(["forumId": "1937071", "forumName": "yy小说吧"])
    guard let fullForum, let nameOnly, let anotherForum else { throw FixtureFailure("Missing fixture forum") }
    try expect(fullForum.matches(nameOnly) && !fullForum.matches(anotherForum), "F02 exact name fallback preserves a known FID conflict")
    try expect(TiebaThreadCardTarget.forumFeedback(event, personalized: true) == nil, "F02 local hiding cannot send ambiguous feedback")
    try expect(TiebaThreadCardTarget.forumFeedback(topic, personalized: true)?.forumId == "31", "F02 ordinary feedback uses the card forum")
    await InteractionTransport.shared.reset()
    try await TiebaFeedAPI.submitDislike(threadId: feedback.threadId, dislikeIds: "17", forumId: feedback.forumId)
    let feedbackWrites = await InteractionTransport.shared.calls
    guard let sent = feedbackWrites.first, let json = sent.fields["dislike"],
          let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
      throw FixtureFailure("Feedback wire body absent")
    }
    try expect(
      feedbackWrites.count == 1 && sent.path == "/c/c/excellent/submitDislike" && sent.fields["dislike_from"] == "homepage"
        && (rows.first?["tid"] as? String) == "123" && (rows.first?["fid"] as? String) == "31"
        && (rows.first?["dislike_ids"] as? String) == "17" && (rows.first?["extra"] as? String) == ""
        && (rows.first?["click_time"] as? Int ?? 0) > 0,
      "F01 preserves the serialized ordinary feedback fields"
    )
    guard let forumFeedback = TiebaThreadCardTarget.forumFeedback(topic, personalized: true) else {
      throw FixtureFailure("Missing ordinary forum-feedback target")
    }
    try await TiebaFeedAPI.submitDislike(threadId: forumFeedback.threadId, dislikeIds: "7", forumId: forumFeedback.forumId)
    let forumWrites = await InteractionTransport.shared.calls
    guard let forumJSON = forumWrites.last?.fields["dislike"],
          let forumRows = try JSONSerialization.jsonObject(with: Data(forumJSON.utf8)) as? [[String: Any]] else {
      throw FixtureFailure("Missing forum-feedback form")
    }
    try expect(
      forumWrites.count == 2 && (forumRows.first?["tid"] as? String) == "123"
        && (forumRows.first?["fid"] as? String) == "31" && (forumRows.first?["dislike_ids"] as? String) == "7",
      "F02 only the eligible topic sends reason 7 for its forum"
    )
    await InteractionTransport.shared.reset()
    try await TiebaThreadActionAPI.setStore(threadId: share.threadId, firstPostId: "789", store: true)
    try await TiebaThreadActionAPI.setStore(threadId: share.threadId, firstPostId: "789", store: false)
    let stored = await InteractionTransport.shared.calls
    try expect(
      stored.count == 2 && stored[0].path == "/c/c/post/addstore"
        && stored[0].fields["data"] == "[{\"tid\":\"11230786026\",\"pid\":\"789\",\"status\":1}]"
        && stored[1].path == "/c/c/post/rmstore" && stored[1].fields["tid"] == "11230786026",
      "R04 collection payload uses the opened thread KZ and its first floor"
    )
  }

  static func verifyAgreeState(
    topic: TiebaThreadCardTarget.AgreeTarget, reply: TiebaThreadCardTarget.AgreeTarget, sibling: TiebaThreadCardTarget.AgreeTarget
  ) async throws {
    var state = TiebaFeedAgreeState()
    guard let original = state.begin(target: reply, account: "old", desired: false) else {
      throw FixtureFailure("Cannot start unagree")
    }
    let duplicate = state.begin(target: reply, account: "old", desired: true)
    try expect(duplicate == nil, "L08 a duplicate row cannot submit another write")
    try expect(
      state.desired(for: reply, account: "old") == false && state.desired(for: sibling, account: "old") == nil
        && state.desired(for: topic, account: "old") == nil,
      "L09 projection is isolated by reply anchor"
    )
    let baseline = TiebaFeedAgreeState.Count(liked: true, count: 0)
    try expect(baseline.setting(false).count == 0, "Clamp optimistic decrement")
    await InteractionTransport.shared.reset(code: 4)
    do {
      try await TiebaThreadActionAPI.setAgree(threadId: "123", postId: "789", agree: false)
      throw FixtureFailure("Failed write became success")
    } catch TiebaForumAPIError.api(4, _) {}
    let failed = await InteractionTransport.shared.calls
    try expect(failed.count == 1, "L07 business failure is one write")
    let restored = state.finish(original)
    let visible = state.desired(for: reply, account: "old").map { baseline.setting($0) } ?? baseline
    try expect(restored && visible == baseline, "L07 failure restores the exact baseline")

    await InteractionTransport.shared.reset()
    guard let firstTap = state.begin(target: topic, account: "old", desired: true) else {
      throw FixtureFailure("Missing first tap")
    }
    if let secondTap = state.begin(target: topic, account: "old", desired: false) {
      _ = try await TiebaThreadActionAPI.setFeedAgree(topic, agree: secondTap.desired, validateSession: {})
    }
    _ = try await TiebaThreadActionAPI.setFeedAgree(topic, agree: firstTap.desired, validateSession: {})
    let rapidWrites = await InteractionTransport.shared.calls
    try expect(rapidWrites.count == 1 && rapidWrites.first?.fields["op_type"] == "0", "L08 two taps yield one serialized write")
    _ = state.finish(firstTap)

    let accepted = TiebaMutex(true)
    await InteractionTransport.shared.reset()
    do {
      try await TiebaSession.$duringTbs.withValue({ accepted.withLock { $0 = false } }) {
        try await TiebaThreadActionAPI.setAgree(threadId: "123", postId: "789", agree: true, validateSession: {
          guard accepted.withLock({ $0 }) else { throw CancellationError() }
        })
      }
      throw FixtureFailure("Old account write reached transport")
    } catch is CancellationError {}
    let oldWrites = await InteractionTransport.shared.calls
    try expect(oldWrites.isEmpty, "L10 session change during credentials retrieval sends no write")
    let old = state.begin(target: reply, account: "old", desired: true)
    let new = state.begin(target: reply, account: "new", desired: false)
    guard let old, new != nil else { throw FixtureFailure("New account cannot begin") }
    let stale = state.finish(old)
    try expect(!stale && state.desired(for: reply, account: "new") == false, "L10 old completion cannot clear new state")
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
    try await verifyInteractions()
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
