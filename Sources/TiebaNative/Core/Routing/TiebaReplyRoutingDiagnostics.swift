#if DEBUG
import Foundation
import os

/// Enable locally with the -TiebaDebugReplyRouting launch argument.
enum TiebaReplyRoutingDiagnostics {
  static let enabled = ProcessInfo.processInfo.arguments.contains("-TiebaDebugReplyRouting")
  static let presenceKey = "_replyRoutingPresence"
  private static let log = Logger(subsystem: "com.tiebalite.app", category: "reply-routing")

  static func rawPresence(_ raw: [String: Any]) -> String {
    let keys = [
      "id", "threadId", "thread_id", "tid", "postId", "post_id", "firstPostId", "first_post_id",
      "forumId", "forum_id", "originThreadInfo", "origin_thread_info",
    ]
    let origin = raw["originThreadInfo"] as? [String: Any] ?? [:]
    let snakeOrigin = raw["origin_thread_info"] as? [String: Any] ?? [:]
    let hits = keys.filter { raw[$0] != nil }
    let nestedHits = ["tid", "pid", "fid"].filter { origin[$0] != nil || snakeOrigin[$0] != nil }
    return hits.joined(separator: ",") + " originKeys=" + nestedHits.joined(separator: ",")
  }

  static func card(_ row: [String: Any], target: TiebaThreadCardTarget?) {
    guard enabled else { return }
    let origin = row["originThreadInfo"] as? [String: Any]
    let present = row[presenceKey] as? String ?? "unavailable"
    let kind = target?.kind.rawValue ?? "unresolved"
    let raw = [
      "id=\(id(row["id"]))", "threadId=\(id(row["threadId"]))",
      "postId=\(id(row["postId"]))", "firstPostId=\(id(row["firstPostId"]))",
      "forumId=\(id(row["forumId"]))", "routingForumId=\(id(row["routingForumId"]))",
      "originTid=\(id(origin?["threadId"]))", "originPid=\(id(origin?["pid"]))",
      "originFid=\(id(origin?["forumId"]))",
    ].joined(separator: " ")
    let route = "kz=\(id(target?.threadId)) pid=\(id(target?.postId)) fid=\(id(target?.forumId))"
    log.debug("tap kind=\(kind, privacy: .public) hasOrigin=\(origin != nil, privacy: .public) isShare=\(row["isShareThread"] as? Bool == true, privacy: .public) presence=\(present, privacy: .public) \(raw, privacy: .public) route \(route, privacy: .public)")
  }

  static func request(_ request: TiebaThreadPageRequest) {
    guard enabled else { return }
    log.debug("pb/page request \(coordinates(request), privacy: .public) pn=\(request.pageNumber, privacy: .public)")
  }

  static func response(_ request: TiebaThreadPageRequest, code: Int32) {
    guard enabled else { return }
    log.debug("pb/page response \(coordinates(request), privacy: .public) code=\(code, privacy: .public)")
  }

  private static func coordinates(_ request: TiebaThreadPageRequest) -> String {
    "kz=\(request.threadID) pid=\(id(request.postID)) fid=\(id(request.forumID))"
  }

  private static func id(_ value: Any?) -> String {
    TiebaRoutePath.positiveID(value).map { String($0) } ?? "-"
  }
}
#endif
