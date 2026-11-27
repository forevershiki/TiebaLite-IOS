import Foundation

private enum TestFailure: Error {
  case assertion(String)
}

private struct RecordedForm: Sendable {
  let url: URL
  let headers: [String: String]
  let body: String
}

private actor Server {
  enum Reply: Sendable {
    case response(Int, String)
    case error(URLError.Code)
    case paused
  }

  private var replies: [Reply]
  private var records: [RecordedForm] = []
  private var waiting: CheckedContinuation<Void, Never>?
  private var started: CheckedContinuation<Void, Never>?

  init(_ replies: [Reply]) { self.replies = replies }

  func send(_ url: URL, _ headers: [String: String], _ body: String) async throws -> (Int, Data) {
    records.append(RecordedForm(url: url, headers: headers, body: body))
    guard !replies.isEmpty else { throw TestFailure.assertion("unexpected request") }
    switch replies.removeFirst() {
    case .response(let status, let json): return (status, Data(json.utf8))
    case .error(let code): throw URLError(code)
    case .paused:
      await withCheckedContinuation { continuation in
        waiting = continuation
        started?.resume()
        started = nil
      }
      try Task.checkCancellation()
      return (200, Data(#"{"no":0,"data":{"pid":9001}}"#.utf8))
    }
  }

  func forms() -> [RecordedForm] { records }

  func waitForFinal() async {
    if waiting != nil { return }
    await withCheckedContinuation { started = $0 }
  }

  func resumeFinal() {
    waiting?.resume()
    waiting = nil
  }
}

@main
@MainActor
private enum ComposerTests {
  private static let forum = TiebaComposerForum(id: "100", name: "C++ & 游戏吧")
  private static let recipient = TiebaComposerRecipient(id: "56", name: "被回复用户", summary: "原文")
  private static let topic = TiebaComposerTarget.topic(forum)
  private static let thread = TiebaComposerTarget.thread(forum, threadID: "101", title: "示例")
  private static let floor = TiebaComposerTarget.floor(forum, threadID: "101", parentID: "202", floor: 2, recipient: recipient)
  private static let comment = TiebaComposerTarget.comment(
    forum, threadID: "101", parentID: "202", floor: 2, commentID: "303", recipient: recipient
  )
  private static let identity = TiebaComposerIdentity(uid: "88", bduss: "test-bduss", stoken: "test-stoken", nickname: "夹具")
  private static let login = Server.Reply.response(200, #"{"error_code":0,"user":{"id":88},"anti":{"tbs":"fresh"}}"#)
  private static let text = "空 格 + & # /\n回复 👩🏽‍💻 #(滑稽)"
  private static let draft = TiebaComposerDraft(title: "标题", body: text)

  static func main() async throws {
    try await formsForEveryTarget()
    try await rejectedBeforeNetwork()
    try await uploads()
    try await outcomes()
    try await accountChange()
    try await duplicateAndCancellation()
    try await drafts()
    print("Composer regression cases passed")
  }

  private static func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure.assertion(message) }
  }

  private static func expectFailure(_ expected: TiebaComposerFailure, _ operation: () async throws -> Void) async throws {
    do {
      try await operation()
      throw TestFailure.assertion("missing failure: \(expected)")
    } catch let actual as TiebaComposerFailure {
      try expect(actual == expected, "expected \(expected), got \(actual)")
    }
  }

  private static func pipeline(_ server: Server) -> TiebaComposerSubmission {
    TiebaComposerSubmission(transport: TiebaComposerTransport(
      send: { try await server.send($0, $1, $2) }, signLogin: { _ in "test-sign" }, now: { 1_234 }
    ))
  }

  private static func fields(_ body: String) -> [String: String] {
    func decode(_ value: Substring) -> String {
      value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
    }
    return Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { field in
      let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      return (decode(parts[0]), decode(parts[1]))
    })
  }

  private static func formsForEveryTarget() async throws {
    let cases: [(TiebaComposerTarget, String, String?, String?, TiebaComposerDestination)] = [
      (topic, "/f/commit/thread/add", nil, nil, .topic("101")),
      (thread, "/mo/q/apubpost", nil, nil, .thread("101", postID: "901")),
      (floor, "/mo/q/apubpost", "202", nil, .floor(threadID: "101", parentID: "202", postID: "901")),
      (comment, "/mo/q/apubpost", "202", "303", .floor(threadID: "101", parentID: "202", postID: "901")),
    ]
    for (target, path, pid, lzl, destination) in cases {
      let reply = target.showsTitle ? #"{"result":"1","tid":"101","pid":"901"}"# : #"{"no":0,"data":{"tid":101,"pid":901}}"#
      let server = Server([login, .response(200, reply)])
      var beforeSend = false
      let receipt = try await pipeline(server).submit(target: target, draft: draft, identity: identity,
        validateSession: {}, willSend: { beforeSend = true }, progress: { _ in })
      let requests = await server.forms()
      try expect(beforeSend && requests.map(\.url.path) == ["/c/s/login", path], "single final POST")
      try expect(TiebaComposerProtocol.destination(for: target, receipt: receipt) == destination, "correct refresh destination")
      try expect(requests[0].headers["Cookie"] == nil, "login excludes cookies")
      try expect(requests[1].headers["Cookie"] == "BDUSS=test-bduss; STOKEN=test-stoken", "minimal web cookies")
      let form = fields(requests[1].body)
      try expect(form["fid"] == "100" && form["tbs"] == "fresh", "forum and fresh tbs")
      if target.showsTitle {
        try expect(form["kw"] == forum.name && form["title"] == "标题" && form["content"] == text, "Unicode topic")
        try expect(Set(form.keys) == ["ie", "fid", "kw", "tbs", "title", "content", "nick_name", "bsk"], "topic form keys")
      } else {
        try expect(form["word"] == forum.name && form["z"] == "101", "canonical forum and thread")
        try expect(form["pid"] == pid && form["floor"] == (pid == nil ? nil : "2"), "parent floor binding")
        try expect(form["lzl_id"] == lzl, "comment binding")
        try expect(form["co"] == (lzl == nil ? text : "回复 被回复用户 : \(text)"), "Unicode reply")
        try expect(requests[1].url.query == "_t=1234" && form["_BSK"] == "1234", "same timestamp")
      }
    }
  }

  private static func rejectedBeforeNetwork() async throws {
    let server = Server([])
    let submission = pipeline(server)
    let invalid = TiebaComposerTarget.floor(forum, threadID: "101", parentID: "", floor: 2, recipient: recipient)
    let noFloor = TiebaComposerTarget.floor(forum, threadID: "101", parentID: "202", floor: 0, recipient: recipient)
    let invalidComment = TiebaComposerTarget.comment(forum, threadID: "101", parentID: "202", floor: 2, commentID: "202", recipient: recipient)
    let cases: [(TiebaComposerTarget, TiebaComposerDraft, TiebaComposerIdentity?, TiebaComposerFailure)] = [
      (topic, draft, nil, .login),
      (invalid, draft, identity, .invalidTarget),
      (noFloor, draft, identity, .invalidTarget),
      (invalidComment, draft, identity, .invalidTarget),
      (topic, .init(title: "  ", body: "正文"), identity, .validation("请输入标题。")),
      (topic, .init(title: "标题", body: "\n "), identity, .validation("请输入正文或添加图片。")),
      (thread, .init(), identity, .validation("请输入正文或添加图片。")),
      (thread, .init(body: "已有内容", outcomeUnknown: true), identity, .unknown),
    ]
    for (target, value, identity, error) in cases {
      try await expectFailure(error) {
        _ = try await submission.submit(target: target, draft: value, identity: identity,
          validateSession: {}, willSend: { throw TestFailure.assertion("unsafe write") }, progress: { _ in })
      }
    }
    try expect(await server.forms().isEmpty, "validation must stop before network")
  }

  private static func uploads() async throws {
    let image = Data([0xfb, 0xef, 0xff])
    let photoDraft = TiebaComposerDraft(body: "图片回复", images: [image, image])
    let server = Server([
      .response(200, #"{"err_code":"0","image_info":"first-image"}"#),
      .response(200, #"{"imageInfo":"second-image"}"#),
      login, .response(200, #"{"no":0}"#),
    ])
    var progress: [TiebaComposerProgress] = []
    _ = try await pipeline(server).submit(target: comment, draft: photoDraft, identity: identity,
      validateSession: {}, willSend: {}, progress: { progress.append($0) })
    let requests = await server.forms()
    try expect(requests.map(\.url.path) == ["/mo/q/cooluploadpic", "/mo/q/cooluploadpic", "/c/s/login", "/mo/q/apubpost"], "upload sequence")
    try expect(fields(requests[0].body) == ["pic": image.base64EncodedString()], "upload bytes survive form encoding")
    try expect(fields(requests[3].body)["upload_img_info"] == "first-image|second-image", "opaque media references")
    try expect(progress == [.uploading(1, 2), .uploading(2, 2), .preparing, .sending], "upload progress")

    let failed = Server([.response(200, #"{"error_code":7,"error_msg":"上传被拒绝"}"#)])
    try await expectFailure(.business(7, "上传被拒绝")) {
      _ = try await pipeline(failed).submit(target: floor, draft: photoDraft, identity: identity,
        validateSession: {}, willSend: { throw TestFailure.assertion("sent after upload failure") }, progress: { _ in })
    }
    try expect(await failed.forms().count == 1, "upload error stops final write")
  }

  private static func outcomes() async throws {
    let cases: [(Server.Reply, TiebaComposerFailure)] = [
      (.response(503, "unavailable"), .unknown),
      (.error(.timedOut), .unknown),
      (.response(200, #"{"no":42,"error":"发言频率限制"}"#), .business(42, "发言频率限制")),
      (.response(200, #"{"no":0,"data":{"need_vcode":1}}"#), .verification),
      (.response(200, #"{"no":0,"data":{"tid":999}}"#), .unknown),
      (.response(200, #"{"no":0,"errno":1}"#), .unknown),
      (.response(200, #"{"no":true}"#), .unknown),
      (.response(200, #"{"no":0,"pid":9.5}"#), .unknown),
      (.response(200, "<html>challenge</html>"), .unknown),
      (.response(200, "{}"), .unknown),
    ]
    for (response, failure) in cases {
      let server = Server([login, response])
      try await expectFailure(failure) {
        _ = try await pipeline(server).submit(target: thread, draft: draft, identity: identity,
          validateSession: {}, willSend: {}, progress: { _ in })
      }
      try expect(await server.forms().count == 2, "ambiguous or explicit failure must not retry")
    }
    let noTopicID = Server([login, .response(200, #"{"result":1}"#)])
    try await expectFailure(.unknown) {
      _ = try await pipeline(noTopicID).submit(target: topic, draft: draft, identity: identity,
        validateSession: {}, willSend: {}, progress: { _ in })
    }
  }

  private static func accountChange() async throws {
    let server = Server([login])
    var checks = 0
    try await expectFailure(.accountChanged) {
      _ = try await pipeline(server).submit(target: thread, draft: draft, identity: identity,
        validateSession: {
          checks += 1
          if checks == 2 { throw TiebaComposerFailure.accountChanged }
        },
        willSend: { throw TestFailure.assertion("sent under changed account") }, progress: { _ in })
    }
    try expect(await server.forms().count == 1, "switch during preflight blocks write")
    let badLogin = Server([.response(200, #"{"error_code":5,"anti":{"tbs":"stale"}}"#)])
    try await expectFailure(.business(5, "")) {
      _ = try await pipeline(badLogin).submit(target: topic, draft: draft, identity: identity,
        validateSession: {}, willSend: { throw TestFailure.assertion("sent with invalid login") }, progress: { _ in })
    }
  }

  private static func duplicateAndCancellation() async throws {
    let server = Server([login, .paused])
    let submission = pipeline(server)
    let first = Task {
      try await submission.submit(target: thread, draft: draft, identity: identity,
        validateSession: {}, willSend: {}, progress: { _ in })
    }
    await server.waitForFinal()
    try await expectFailure(.busy) {
      _ = try await submission.submit(target: thread, draft: draft, identity: identity,
        validateSession: {}, willSend: {}, progress: { _ in })
    }
    first.cancel()
    await server.resumeFinal()
    try await expectFailure(.unknown) { _ = try await first.value }
    try expect(await server.forms().count == 2, "double tap and cancellation keep single final write")
  }

  private static func drafts() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = TiebaComposerDraftStore(directory: folder)
    defer { try? store.removeAll() }
    for (index, target) in [topic, thread, floor, comment].enumerated() {
      let state = try TiebaComposerEditorState(store: store, accountID: "88", target: target)
      state.edit(title: "草稿", body: "目标 \(index)")
      if !target.showsTitle { state.setImages([Data([1, 2, 3])]) }
      try state.save()
    }
    for (index, target) in [topic, thread, floor, comment].enumerated() {
      let restored = try TiebaComposerEditorState(store: store, accountID: "88", target: target)
      let other = try TiebaComposerEditorState(store: store, accountID: "99", target: target)
      try expect(restored.draft.body == "目标 \(index)" && other.draft.isEmpty, "account and target isolation")
      try expect(restored.draft.images.count == (target.showsTitle ? 0 : 1), "attachments restore")
    }

    let state = try TiebaComposerEditorState(store: store, accountID: "88", target: thread)
    let blocked = Server([.response(200, #"{"image_info":"fixture"}"#), login, .response(200, #"{"no":42}"#)])
    try await expectFailure(.business(42, "")) {
      _ = try await state.submit(through: pipeline(blocked), identity: identity, validateSession: {}, progress: { _ in })
    }
    try expect(!state.draft.outcomeUnknown && state.draft.body == "目标 1", "confirmed rejection retains draft for editing")

    let timedOut = Server([.response(200, #"{"image_info":"fixture"}"#), login, .error(.timedOut)])
    try await expectFailure(.unknown) {
      _ = try await state.submit(through: pipeline(timedOut), identity: identity, validateSession: {}, progress: { _ in })
    }
    let reopened = try TiebaComposerEditorState(store: store, accountID: "88", target: thread)
    try expect(reopened.draft.outcomeUnknown && reopened.draft.body == "目标 1", "failed write preserves editable content and check marker")
    try reopened.setOutcomeUnknown(false)
    let succeeded = Server([.response(200, #"{"image_info":"fixture"}"#), login, .response(200, #"{"no":0}"#)])
    let result = try await reopened.submit(through: pipeline(succeeded), identity: identity, validateSession: {}, progress: { _ in })
    try expect(result.draftCleared && result.destination == .thread("101", postID: nil), "success clears draft and routes correctly")
    try expect(try store.load(accountID: "88", target: thread).isEmpty, "confirmed result clears draft")
    try expect(try store.load(accountID: "88", target: comment).body == "目标 3", "clear only current target")
  }
}
