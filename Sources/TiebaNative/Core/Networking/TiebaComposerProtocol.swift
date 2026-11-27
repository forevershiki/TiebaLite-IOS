import CoreFoundation
import Foundation

struct TiebaComposerForum: Equatable, Sendable {
  let id: String
  let name: String
}

struct TiebaComposerRecipient: Equatable, Sendable {
  let id: String
  let name: String
  let summary: String
}

enum TiebaComposerTarget: Equatable, Sendable {
  case topic(TiebaComposerForum)
  case thread(TiebaComposerForum, threadID: String, title: String)
  case floor(TiebaComposerForum, threadID: String, parentID: String, floor: Int, recipient: TiebaComposerRecipient)
  case comment(TiebaComposerForum, threadID: String, parentID: String, floor: Int, commentID: String, recipient: TiebaComposerRecipient)

  var forum: TiebaComposerForum {
    switch self {
    case .topic(let forum), .thread(let forum, _, _), .floor(let forum, _, _, _, _),
      .comment(let forum, _, _, _, _, _): forum
    }
  }

  var threadID: String? {
    switch self {
    case .topic: nil
    case .thread(_, let id, _), .floor(_, let id, _, _, _), .comment(_, let id, _, _, _, _): id
    }
  }

  var parentID: String? {
    switch self {
    case .floor(_, _, let id, _, _), .comment(_, _, let id, _, _, _): id
    case .topic, .thread: nil
    }
  }

  var draftComponents: [String] {
    switch self {
    case .topic(let forum): ["topic", forum.id]
    case .thread(let forum, let thread, _): ["thread", forum.id, thread]
    case .floor(let forum, let thread, let parent, _, _): ["floor", forum.id, thread, parent]
    case .comment(let forum, let thread, let parent, _, let comment, _):
      ["comment", forum.id, thread, parent, comment]
    }
  }

  var showsTitle: Bool { threadID == nil }

  func validate() throws {
    guard Self.isPositiveID(forum.id, signed: true),
      !forum.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !(forum.name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }),
      threadID.map({ Self.isPositiveID($0, signed: true) }) ?? true
    else { throw TiebaComposerFailure.invalidTarget }
    switch self {
    case .topic, .thread: break
    case .floor(_, _, let parent, let floor, _):
      guard Self.isPositiveID(parent), floor > 0 else { throw TiebaComposerFailure.invalidTarget }
    case .comment(_, _, let parent, let floor, let comment, _):
      guard Self.isPositiveID(parent), floor > 0, Self.isPositiveID(comment), comment != parent
      else { throw TiebaComposerFailure.invalidTarget }
    }
  }

  static func isPositiveID(_ value: String, signed: Bool = false) -> Bool {
    guard let number = UInt64(value), number > 0, String(number) == value else { return false }
    return !signed || number <= UInt64(Int64.max)
  }
}

struct TiebaComposerDraft: Codable, Equatable, Sendable {
  var title = ""
  var body = ""
  var images: [Data] = []
  var outcomeUnknown = false

  var isEmpty: Bool { title.isEmpty && body.isEmpty && images.isEmpty && !outcomeUnknown }

  func validate(for target: TiebaComposerTarget) throws {
    try target.validate()
    if target.showsTitle {
      guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw TiebaComposerFailure.validation("请输入标题。")
      }
      guard title.count <= 64 else { throw TiebaComposerFailure.validation("标题最多 64 个字符。") }
      guard images.isEmpty else { throw TiebaComposerFailure.validation("主题帖暂不支持附件。") }
    }
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else {
      throw TiebaComposerFailure.validation("请输入正文或添加图片。")
    }
    guard body.count <= 10_000 else { throw TiebaComposerFailure.validation("正文最多 10000 个字符。") }
    guard images.count <= Self.maximumImages,
      images.allSatisfy({ !$0.isEmpty && $0.count <= Self.maximumImageBytes })
    else { throw TiebaComposerFailure.validation("最多添加 9 张图片，每张最多 10 MiB。") }
  }

  static let maximumImages = 9
  static let maximumImageBytes = 10 * 1024 * 1024
}

enum TiebaComposerFailure: LocalizedError, Equatable {
  case login
  case disabled
  case accountChanged
  case invalidTarget
  case validation(String)
  case business(Int, String)
  case verification
  case preparation
  case upload
  case cancelled
  case unknown
  case busy
  case draft

  var errorDescription: String? {
    switch self {
    case .login: "请登录拥有完整凭据的贴吧账号后发言。"
    case .disabled: "请在「设置 → 更多设置」中开启实验性发言。"
    case .accountChanged: "账号已切换。请从当前账号重新打开编辑器。"
    case .invalidTarget: "缺少有效的贴吧、帖子或回复目标。请刷新页面后再试。"
    case .validation(let message): message
    case .business(let code, let message):
      message.isEmpty ? "贴吧拒绝了请求（\(code)）。" : "贴吧拒绝了请求（\(code)）：\(message)"
    case .verification: "贴吧要求验证或限制了发言。请通过官方客户端查看处理。"
    case .preparation: "无法验证发言登录状态。请检查网络或重新登录。"
    case .upload: "图片上传失败，正文尚未发送。"
    case .cancelled: "操作已取消，正文尚未发送。"
    case .unknown: "发送结果未知。请先查看帖子或回复是否已发布，再决定是否重试。"
    case .busy: "已有一条发言正在发送。"
    case .draft: "本地草稿暂时无法读取或保存。"
    }
  }
}

struct TiebaComposerReceipt: Equatable, Sendable {
  let threadID: String
  let postID: String?
}

enum TiebaComposerDestination: Equatable {
  case topic(String)
  case thread(String, postID: String?)
  case floor(threadID: String, parentID: String, postID: String?)
}

enum TiebaComposerProtocol {
  static let host = "https://tieba.baidu.com"
  static let topicPath = "/f/commit/thread/add"
  static let replyPath = "/mo/q/apubpost"
  static let uploadPath = "/mo/q/cooluploadpic"

  static func fields(
    target: TiebaComposerTarget, draft: TiebaComposerDraft, tbs: String,
    nickname: String, timestamp: String, imageInfo: [String]
  ) throws -> [String: String] {
    try target.validate()
    switch target {
    case .topic(let forum):
      return [
        "ie": "utf-8", "fid": forum.id, "kw": forum.name, "tbs": tbs,
        "title": draft.title, "content": draft.body, "nick_name": nickname, "bsk": timestamp,
      ]
    default:
      guard let id = target.threadID else { throw TiebaComposerFailure.invalidTarget }
      var parameters = [
        "co": draft.body, "_t": timestamp, "tag": "11", "upload_img_info": imageInfo.joined(separator: "|"),
        "fid": target.forum.id, "src": "1", "word": target.forum.name, "tbs": tbs,
        "z": id, "lp": "6026", "nick_name": nickname, "_BSK": timestamp,
      ]
      switch target {
      case .floor(_, _, let id, let floor, _):
        parameters["pid"] = id
        parameters["floor"] = String(floor)
      case .comment(_, _, let parent, let floor, let comment, let recipient):
        parameters["pid"] = parent
        parameters["floor"] = String(floor)
        parameters["lzl_id"] = comment
        let name = recipient.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name.utf8.count <= 512, !name.contains(","), !name.contains(")"),
          !(name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }) {
          parameters["co"] = "回复 \(name) : \(draft.body)"
        }
      case .thread, .topic: break
      }
      return parameters
    }
  }

  static func destination(for target: TiebaComposerTarget, receipt: TiebaComposerReceipt) -> TiebaComposerDestination {
    if let parentID = target.parentID {
      return .floor(threadID: receipt.threadID, parentID: parentID, postID: receipt.postID)
    }
    if target.showsTitle { return .topic(receipt.threadID) }
    return .thread(receipt.threadID, postID: receipt.postID)
  }

  static func receipt(status: Int, data: Data, target: TiebaComposerTarget) throws -> TiebaComposerReceipt {
    guard (200..<300).contains(status) else {
      switch status {
      case 401: throw TiebaComposerFailure.business(status, "登录校验失败，请检查登录状态。")
      case 403: throw TiebaComposerFailure.business(status, "发言受到限制，请通过官方客户端查看。")
      case 429: throw TiebaComposerFailure.business(status, "操作频率受限，请稍后再试。")
      default: throw TiebaComposerFailure.unknown
      }
    }
    let objects = try objects(from: data)
    try checkVerification(objects)
    let code = try uniqueInteger(objects, keys: ["error_code", "err_code", "no", "errno", "error_no"])
    let result = try uniqueInteger(objects, keys: ["result"])
    if let code, let result, (code == 0) != (result == 1) { throw TiebaComposerFailure.unknown }
    if let code, code != 0 { throw TiebaComposerFailure.business(code, message(in: objects)) }
    if let result, result != 1 { throw TiebaComposerFailure.business(result, message(in: objects)) }
    guard code == 0 || result == 1 else { throw TiebaComposerFailure.unknown }
    let returnedThread = try identifier(objects, keys: ["tid"], signed: true)
    let post = try identifier(objects, keys: ["pid", "post_id"])
    if let expected = target.threadID {
      guard returnedThread == nil || returnedThread == expected else { throw TiebaComposerFailure.unknown }
      return TiebaComposerReceipt(threadID: expected, postID: post)
    }
    guard let returnedThread else { throw TiebaComposerFailure.unknown }
    return TiebaComposerReceipt(threadID: returnedThread, postID: post)
  }

  static func uploadedImage(status: Int, data: Data) throws -> String {
    guard (200..<300).contains(status) else { throw TiebaComposerFailure.upload }
    let objects = try objects(from: data)
    try checkVerification(objects)
    if let code = try uniqueInteger(objects, keys: ["error_code", "err_code"]), code != 0 {
      throw TiebaComposerFailure.business(code, message(in: objects))
    }
    guard let value = objects[0]["image_info"] as? String ?? objects[0]["imageInfo"] as? String,
      !value.isEmpty, value.utf8.count <= 16_384,
      !value.contains("|"),
      !(value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    else { throw TiebaComposerFailure.upload }
    return value
  }

  static func postingTBS(status: Int, data: Data, accountID: String) throws -> String {
    guard (200..<300).contains(status) else { throw TiebaComposerFailure.preparation }
    let objects = try objects(from: data)
    try checkVerification(objects)
    if let code = try uniqueInteger(objects, keys: ["error_code", "err_code", "code"]), code != 0 {
      throw TiebaComposerFailure.business(code, message(in: objects))
    }
    for object in objects {
      if let user = object["user"] as? [String: Any],
        let id = try identifier([user], keys: ["id", "uid", "user_id"]), id != accountID {
        throw TiebaComposerFailure.accountChanged
      }
    }
    for object in objects {
      if let anti = object["anti"] as? [String: Any],
        let tbs = (anti["tbs"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
        !tbs.isEmpty { return tbs }
    }
    throw TiebaComposerFailure.preparation
  }

  static func form(_ fields: [String: String]) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
    func encode(_ string: String) -> String {
      (string.addingPercentEncoding(withAllowedCharacters: allowed) ?? "").replacingOccurrences(of: "%20", with: "+")
    }
    return fields.keys.sorted().map { "\(encode($0))=\(encode(fields[$0, default: ""]))" }.joined(separator: "&")
  }

  private static func objects(from data: Data) throws -> [[String: Any]] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { throw TiebaComposerFailure.unknown }
    if let nested = root["data"] as? [String: Any] { return [root, nested] }
    if let nested = root["data"], !(nested is NSNull) { throw TiebaComposerFailure.unknown }
    return [root]
  }

  private static func integerString(_ value: Any) -> String? {
    if let text = value as? String { return text }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
    return number.stringValue
  }

  private static func uniqueInteger(_ objects: [[String: Any]], keys: [String]) throws -> Int? {
    let values = try objects.flatMap { object in
      try keys.compactMap { key -> Int? in
        guard let raw = object[key] else { return nil }
        guard let text = integerString(raw), let value = Int(text), String(value) == text
        else { throw TiebaComposerFailure.unknown }
        return value
      }
    }
    guard Set(values).count <= 1 else { throw TiebaComposerFailure.unknown }
    return values.first
  }

  private static func identifier(_ objects: [[String: Any]], keys: [String], signed: Bool = false) throws -> String? {
    let values = try objects.flatMap { object in
      try keys.compactMap { key -> String? in
        guard let raw = object[key] else { return nil }
        guard let value = integerString(raw), TiebaComposerTarget.isPositiveID(value, signed: signed)
        else { throw TiebaComposerFailure.unknown }
        return value
      }
    }
    guard Set(values).count <= 1 else { throw TiebaComposerFailure.unknown }
    return values.first
  }

  private static func message(in objects: [[String: Any]]) -> String {
    let messages = objects.flatMap { object in
      ["error_msg", "err_msg", "error", "msg", "message", "errorMsg", "errMsg"].compactMap { object[$0] as? String }
    }
    return String((messages.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "").prefix(400))
  }

  private static func checkVerification(_ objects: [[String: Any]]) throws {
    let scopes = objects + objects.flatMap { object in
      ["anti", "info", "security_verify"].compactMap { object[$0] as? [String: Any] }
    }
    let challenged = scopes.contains { object in
      ["need_vcode", "vcode_stat", "need_verify"].contains { key in
        guard let value = object[key] else { return false }
        return ["1", "true"].contains(String(describing: value).lowercased())
      } || ["vcode_md5", "vcode_pic_url", "captcha_url", "verify_url"].contains {
        if let text = object[$0] as? String { return !text.isEmpty }
        return false
      }
    }
    let detail = message(in: scopes).lowercased()
    if challenged || ["验证码", "安全验证", "captcha", "verify"].contains(where: { detail.contains($0) }) {
      throw TiebaComposerFailure.verification
    }
  }
}
