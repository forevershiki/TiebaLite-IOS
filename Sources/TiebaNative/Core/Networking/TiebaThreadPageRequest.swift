import Foundation

struct TiebaThreadPageRequest: Sendable {
  let threadID: Int64
  let postID: Int64?
  let forumID: Int64?
  let pageNumber: Int32

  init(threadId: String, postId: String?, forumId: String?, page: Int) throws {
    guard let threadID = TiebaRoutePath.positiveID(threadId) else {
      throw TiebaThreadPageError.invalidThreadID
    }
    guard let pageNumber = Int32(exactly: page), pageNumber > 0 else {
      throw TiebaThreadPageError.invalidPage
    }
    self.threadID = threadID
    let postID = TiebaRoutePath.positiveID(postId)
    self.postID = postID == threadID ? nil : postID
    self.forumID = TiebaRoutePath.positiveID(forumId)
    // With pid, pn's Protobuf default of zero asks pb/page to locate the reply.
    self.pageNumber = pageNumber == 1 && self.postID != nil ? 0 : pageNumber
  }
}

enum TiebaThreadPageError: LocalizedError, Equatable {
  case invalidThreadID
  case invalidPage
  case invalidProtobuf
  case unexpectedJSON
  case missingData
  case unexpectedThread
  case deleted
  case business(Int, String)
  case missingAnchor

  var allowsStaleCache: Bool {
    switch self {
    case .invalidProtobuf, .unexpectedJSON, .missingData, .unexpectedThread: return true
    default: return false
    }
  }

  var allowsUnanchoredLookup: Bool {
    switch self {
    case .missingAnchor, .business(1989002, _): return true
    default: return false
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidThreadID: return "帖子 ID 缺失或无效"
    case .invalidPage: return "帖子页码无效"
    case .invalidProtobuf: return "无法解析贴吧返回的帖子数据"
    case .unexpectedJSON: return "贴吧返回了意外的 JSON 响应"
    case .missingData: return "贴吧响应缺少帖子内容"
    case .unexpectedThread: return "贴吧返回了与请求不符的帖子"
    case .deleted: return "贴吧显示该帖子已被删除"
    case .missingAnchor: return "未找到指定回复"
    case .business(4, _): return "贴吧未能定位帖子，请检查帖子链接（业务码 4）"
    case .business(let code, let message):
      let detail = message.isEmpty ? "贴吧未能加载帖子" : message
      return "\(detail)（业务码 \(code)）"
    }
  }
}
