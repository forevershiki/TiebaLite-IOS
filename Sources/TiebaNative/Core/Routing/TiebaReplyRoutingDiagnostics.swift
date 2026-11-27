#if DEBUG
import Foundation
import os

enum TiebaReplyRoutingDiagnostics {
  static let presenceKey = "_replyRoutingPresence"
  private static let wirePresenceKey = "_replyRoutingWirePresence"
  private static let log = Logger(subsystem: "com.tiebalite.app", category: "reply-routing")
  private static let state = TiebaMutex(State(
    enabled: ProcessInfo.processInfo.arguments.contains("-TiebaDebugReplyRouting")
  ))

  private struct State: Sendable {
    var enabled: Bool
    var generation = 0
    var latestFailure: String?
  }

  static var enabled: Bool {
    get { state.withLock { $0.enabled } }
    set {
      state.withLock {
        guard $0.enabled != newValue else { return }
        $0.enabled = newValue
        $0.generation += 1
        $0.latestFailure = nil
      }
    }
  }

  static var latestFailure: String? { state.withLock { $0.latestFailure } }

  enum Source: String {
    case personalized, concern, hot, topic, profile
  }

  struct Tap: Sendable {
    fileprivate let generation: Int
    fileprivate let summary: String

    fileprivate func saveFailure(_ details: String) {
      TiebaReplyRoutingDiagnostics.state.withLock {
        guard $0.enabled, $0.generation == generation else { return }
        $0.latestFailure = summary + "\n" + details
      }
    }

    func detailDidAppear(threadId: String, postId: String?) {
      guard TiebaReplyRoutingDiagnostics.state.withLock({ $0.enabled && $0.generation == generation }) else { return }
      let kz = TiebaReplyRoutingDiagnostics.id(threadId)
      let pid = TiebaReplyRoutingDiagnostics.id(postId)
      TiebaReplyRoutingDiagnostics.log.debug("navigation=detail-appeared kz=\(kz, privacy: .public) pid=\(pid, privacy: .public)")
    }
  }

  final class PageAttempt: Sendable {
    private enum Network: String, Sendable {
      case notStarted = "not-started"
      case prepared = "prepared-unconfirmed"
      case responseReceived = "response-received"
    }

    private struct Trace: Sendable {
      var lines: [String] = []
      var network: Network = .notStarted
    }

    private let tap: Tap
    private let stages = TiebaMutex(Trace())

    init(_ tap: Tap) { self.tap = tap }

    func request(_ request: TiebaThreadPageRequest) {
      record("request /c/f/pb/page \(Self.coordinates(request))", network: .prepared)
    }

    func receivedBody() { record("transport=received-body", network: .responseReceived) }

    func loadedFromCache() { record("source=page-cache") }

    func response(_ request: TiebaThreadPageRequest, code: Int32) {
      record("response /c/f/pb/page \(Self.coordinates(request)) code=\(code)", network: .responseReceived)
    }

    func verifiedForNavigation() {
      let network = stages.withLock { $0.network.rawValue }
      record("verification=confirmed navigation=submitted network=\(network)")
    }

    func saveFailure(verifyingReply: Bool = false, error: (any Error)? = nil) {
      let trace = stages.withLock { $0 }
      let result = verifyingReply ? "reply-verification-failed" : "page-load-failed"
      let navigation = verifyingReply ? "not-opened" : "detail-load"
      let network = Self.httpStatus(error) == nil ? trace.network : .responseReceived
      let summary = "result=\(result) reason=\(Self.failureCategory(error)) network=\(network.rawValue) navigation=\(navigation)"
      tap.saveFailure((trace.lines + [summary]).joined(separator: "\n"))
    }

    private func record(_ stage: String, network: Network? = nil) {
      guard TiebaReplyRoutingDiagnostics.state.withLock({ $0.enabled && $0.generation == tap.generation }) else { return }
      stages.withLock {
        $0.lines.append(stage)
        if let network { $0.network = network }
      }
      TiebaReplyRoutingDiagnostics.log.debug("\(stage, privacy: .public)")
    }

    private static func httpStatus(_ error: (any Error)?) -> Int? {
      if let failure = error as? TiebaClientError, case .httpStatus(let status) = failure { return status }
      return nil
    }

    private static func failureCategory(_ error: (any Error)?) -> String {
      if let page = error as? TiebaThreadPageError {
        switch page {
        case .invalidThreadID: return "invalid-thread-id"
        case .invalidPage: return "invalid-page"
        case .invalidProtobuf: return "invalid-protobuf"
        case .unexpectedJSON: return "unexpected-json"
        case .missingData: return "missing-data"
        case .unexpectedThread: return "unconfirmed-thread"
        case .deleted: return "deleted"
        case .business(let code, _): return "business-\(code)"
        case .missingAnchor: return "missing-target-pid"
        }
      }
      if let status = httpStatus(error) { return "http-\(status)" }
      return error == nil ? "unspecified" : "transport-or-local-failure"
    }

    private static func coordinates(_ request: TiebaThreadPageRequest) -> String {
      let pid = TiebaReplyRoutingDiagnostics.id(request.postID)
      let fid = TiebaReplyRoutingDiagnostics.id(request.forumID)
      return "kz=\(request.threadID) pid=\(pid) fid=\(fid) pn=\(request.pageNumber)"
    }
  }

  // Navigation constructs the detail controller synchronously. The controller
  // retains this tap, and binds each initial load or refresh to its own attempt.
  @TaskLocal static var navigationTap: Tap? = nil
  @TaskLocal static var pageAttempt: PageAttempt? = nil

  // Read the original tags, including defaults omitted from proto3 JSON.
  // Only the resulting labels are carried past this call.
  static func addPersonalizedWirePresence(_ bytes: Data, to decoded: inout [String: Any]) {
    let wire = Array(bytes)
    guard let envelope = wireFields(wire[...], messages: [2]),
          let body = envelope.first(where: { $0.tag == 2 })?.message,
          let fields = wireFields(body, messages: [2]),
          var data = decoded["data"] as? [String: Any],
          var rows = data["threadList"] as? [[String: Any]] else { return }
    let threads = fields.filter { $0.tag == 2 }.compactMap(\.message)
    guard threads.count == rows.count else { return }
    for (index, wireThread) in threads.enumerated() {
      guard let thread = wireFields(wireThread, messages: [141, 155]) else { continue }
      var lines = [presence("ThreadInfo", fields: thread, tags: [
        ("id", 1), ("threadId", 2), ("threadTypes", 8), ("forumId", 27),
        ("firstPostId", 40), ("post_id", 52), ("pids", 61), ("origin_thread_info", 141),
        ("is_share_thread", 143), ("forumInfo", 155), ("nid", 164),
      ])]
      for field in thread {
        guard let message = field.message, let nested = wireFields(message) else { continue }
        if field.tag == 141 {
          lines.append(presence("OriginThreadInfo", fields: nested, tags: [("tid", 5), ("fid", 7), ("pid", 25)]))
        } else if field.tag == 155 {
          lines.append(presence("ThreadInfo.forumInfo", fields: nested, tags: [("id", 1)]))
        }
      }
      rows[index][wirePresenceKey] = lines.joined(separator: "\n")
    }
    data["threadList"] = rows
    decoded["data"] = data
  }

  private struct WireField {
    let tag: UInt64
    let message: ArraySlice<UInt8>?
  }

  private static func presence(_ name: String, fields: [WireField], tags: [(String, UInt64)]) -> String {
    let found = Set(fields.map(\.tag))
    let labels = tags.map { "\($0.0)#\($0.1)=\(found.contains($0.1) ? "present" : "absent")" }
    return "wire \(name): " + labels.joined(separator: " ")
  }

  private static func wireFields(_ bytes: ArraySlice<UInt8>, messages: Set<UInt64> = []) -> [WireField]? {
    var cursor = bytes.startIndex
    func varint() -> UInt64? {
      var value: UInt64 = 0
      for shift in stride(from: 0, through: 63, by: 7) {
        guard cursor < bytes.endIndex else { return nil }
        let byte = bytes[cursor]
        cursor += 1
        guard shift != 63 || byte <= 1 else { return nil }
        value |= UInt64(byte & 0x7f) << shift
        if byte < 0x80 { return value }
      }
      return nil
    }

    var fields: [WireField] = []
    while cursor < bytes.endIndex {
      guard let key = varint(), key >> 3 > 0 else { return nil }
      let tag = key >> 3
      var message: ArraySlice<UInt8>?
      switch key & 7 {
      case 0:
        guard varint() != nil else { return nil }
      case 1, 5:
        let width = (key & 7) == 1 ? 8 : 4
        guard width <= bytes.endIndex - cursor else { return nil }
        cursor += width
      case 2:
        guard let length = varint(), length <= UInt64(bytes.endIndex - cursor) else { return nil }
        let end = cursor + Int(length)
        if messages.contains(tag) { message = bytes[cursor..<end] }
        cursor = end
      default:
        return nil
      }
      fields.append(WireField(tag: tag, message: message))
    }
    return fields
  }

  /// Capture allowlisted fields after Protobuf normalization, before mapping.
  static func rawFields(_ raw: [String: Any], forum: [String: Any]? = nil) -> String {
    let forumIDs = ["forumId", "forum_id", "fid"]
    let keys = ["id", "threadId", "thread_id", "tid", "postId", "post_id", "firstPostId", "first_post_id",
                "isShareThread", "is_share_thread", "threadTypes", "thread_types"] + forumIDs
    func fields(_ row: [String: Any], _ keys: [String]) -> String {
      let present = keys.compactMap { key in row[key].map { "\(key)=\(id($0))" } }
      return present.isEmpty ? "-" : present.joined(separator: " ")
    }
    var result = ["raw: \(fields(raw, keys))"]
    for key in ["originThreadInfo", "origin_thread_info"] where raw[key] != nil {
      result.append("raw.\(key): \(fields(raw[key] as? [String: Any] ?? [:], ["tid", "pid"] + forumIDs))")
    }
    for key in ["forumInfo", "forum_info", "forum"] where raw[key] != nil {
      result.append("raw.\(key): \(fields(raw[key] as? [String: Any] ?? [:], ["id"] + forumIDs))")
    }
    if let forum { result.append("raw.containerForum: \(fields(forum, ["id"] + forumIDs))") }
    if let wirePresence = raw[wirePresenceKey] as? String { result.append(wirePresence) }
    return result.joined(separator: "\n")
  }

  static func addingConcernPost(_ post: [String: Any]?, to row: [String: Any]) -> [String: Any] {
    guard let post, let raw = row[presenceKey] as? String else { return row }
    var row = row
    row[presenceKey] = raw + "\nraw.concernPost: present=true id=\(id(post["id"]))"
    return row
  }

  static func card(
    _ row: [String: Any], target: TiebaThreadCardTarget?, source: Source,
    rule: TiebaThreadCardTarget.Opening.Rule = .standardCard
  ) -> Tap? {
    guard let generation = state.withLock({ $0.enabled ? $0.generation : nil }) else { return nil }
    let origin = TiebaViewModelMapper.originThreadInfo(row)
    let raw = row[presenceKey] as? String ?? "raw: unavailable (enable diagnostics and refresh this feed)"
    let post = id(row["postId"])
    let firstPost = id(row["firstPostId"])
    let share = row["isShareThread"] as? Bool == true
    let hasReplyAnchor = post != "-" && post != firstPost
    let cardKind = share ? "reference" : (hasReplyAnchor ? "reply" : "unknown")
    let kind = target?.kind.rawValue ?? cardKind
    let rules = selectionRules(rule, row: row, target: target, origin: origin)
    let mapped = [
      "id=\(id(row["id"]))", "threadId=\(id(row["threadId"]))",
      "postId=\(post)", "firstPostId=\(firstPost)",
      "forumId=\(id(row["forumId"]))", "routingForumId=\(id(row["routingForumId"]))",
      "originTid=\(id(origin?["threadId"]))", "originPid=\(id(origin?["pid"]))",
      "originFid=\(id(origin?["forumId"]))",
    ].joined(separator: " ")
    let summary = """
      tap source=\(source.rawValue) kind=\(kind) hasOrigin=\(origin != nil) isShare=\(share)
      \(raw)
      mapped: \(mapped)
      \(rules)
      route: kz=\(id(target?.threadId)) pid=\(id(target?.postId)) fid=\(id(target?.forumId))
      """
    log.debug("\(summary, privacy: .public)")
    let tap = Tap(generation: generation, summary: summary)
    if target == nil { tap.saveFailure("result=unresolved request=none network=not-started navigation=not-opened") }
    return tap
  }

  private static func selectionRules(
    _ rule: TiebaThreadCardTarget.Opening.Rule, row: [String: Any], target: TiebaThreadCardTarget?,
    origin: [String: Any]?
  ) -> String {
    if rule == .invalidPersonalizedOrigin {
      let originID = TiebaViewModelMapper.firstPositiveID(origin?["threadId"], origin?["thread_id"], origin?["tid"])
      let reason = originID.isEmpty ? "missing-or-invalid" : "equals-target-pid"
      return "rules: kz=rejected OriginThreadInfo.tid#5 reason=\(reason) pid=ThreadInfo.post_id#52 fid=omitted unresolved origin"
    }
    if rule == .invalidPersonalizedOuter {
      return "rules: kz=rejected outer threadId equals target PID pid=ThreadInfo.post_id#52 fid=omitted"
    }
    if rule == .personalizedOrigin {
      let fid = target?.forumId == nil ? "omitted no trusted origin FID" : "OriginThreadInfo.fid#7"
      return "rules: outer=card ID repeats threadId without first-floor evidence kz=OriginThreadInfo.tid#5 (verify target PID) pid=ThreadInfo.post_id#52 fid=\(fid)"
    }
    if case .personalizedOuter(let reason) = rule {
      return "rules: ambiguity=\(reason.rawValue) outer=not trusted without proof kz=ThreadInfo.threadId#2 (verify target PID) pid=ThreadInfo.post_id#52 fid=omitted no trusted topic FID"
    }
    guard let target else { return "rules: kz=unresolved pid=omitted fid=omitted" }
    let useOrigin = target.kind == .reference || (
      id(target.threadId) == id(origin?["threadId"]) && id(target.threadId) != id(row["threadId"])
    )
    let kz = useOrigin ? "OriginThreadInfo.tid#5" : "ThreadInfo.threadId#2 or validated topic-list id#1"
    var pid = "omitted"
    if let postId = target.postId {
      pid = id(postId) == id(row["postId"]) ? "ThreadInfo.post_id#52" : "OriginThreadInfo.pid#25"
    }
    let fid = target.forumId == nil ? "omitted missing or conflicting FID" : "validated route FID"
    return "rules: kz=\(kz) pid=\(pid) fid=\(fid)"
  }

  private static func id(_ value: Any?) -> String {
    TiebaRoutePath.positiveID(value).map { String($0) } ?? "-"
  }
}
#endif
