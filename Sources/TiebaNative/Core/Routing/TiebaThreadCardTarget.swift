/// ThreadInfo.id is a card identity in mixed feeds. Only a topic-list caller
/// can opt into using a bare card ID as the topic.
struct TiebaThreadCardTarget {
  enum Kind: String {
    case topic, reply, reference
  }

  let kind: Kind
  let threadId: String
  let postId: String?
  let forumId: String?
  let forumName: String?

  func route(fromFavorites: Bool = false) -> TiebaRoute {
    .thread(id: threadId, postId: postId, fromFavorites: fromFavorites, forumId: forumId, forumName: forumName)
  }

  static let unresolvedMessage = "暂时无法确定原帖子，请刷新后重试"
  static let unresolvedReplyMessage = "暂时无法定位这条回复，请刷新动态后重试"

  struct Opening {
    enum Rule: Equatable {
      enum OuterReason: String, Equatable {
        case missingOrigin = "missing-origin"
        case differentOriginPID = "different-origin-pid"
      }

      case standardCard, reference, personalizedOrigin
      case personalizedOuter(OuterReason)
      case invalidPersonalizedOrigin, invalidPersonalizedOuter

      var requiresExactReply: Bool {
        switch self {
        case .personalizedOrigin, .personalizedOuter: return true
        default: return false
        }
      }

      var unresolvedMessage: String {
        switch self {
        case .invalidPersonalizedOrigin, .invalidPersonalizedOuter: return TiebaThreadCardTarget.unresolvedReplyMessage
        default: return TiebaThreadCardTarget.unresolvedMessage
        }
      }
    }

    let target: TiebaThreadCardTarget?
    let rule: Rule
  }

  static func opening(_ row: [String: Any], personalized: Bool, reference: Bool = false) -> Opening {
    if reference { return Opening(target: quoted(row), rule: .reference) }
    if personalized, let reply = personalizedReplyOpening(row) { return reply }
    return Opening(target: card(row), rule: .standardCard)
  }

  static func shareURL(for target: Self, verifiedReply: Bool, opening: Opening.Rule) -> String? {
    guard !opening.requiresExactReply || verifiedReply else { return nil }
    return "https://tieba.baidu.com/p/\(target.threadId)"
  }

  struct AgreeTarget: Sendable {
    let threadId: String
    let firstPostId: String?
    let replyAnchor: String?
  }

  /// Feed hearts use the thread-level operation only for an independently identified topic.
  static func agreeTarget(_ row: [String: Any], personalized: Bool) -> AgreeTarget? {
    let opening = opening(row, personalized: personalized)
    guard !opening.rule.requiresExactReply, let target = opening.target, target.kind != .reference,
          target.threadId == TiebaViewModelMapper.firstPositiveID(row["threadId"], row["thread_id"], row["tid"])
    else { return nil }
    let first = TiebaViewModelMapper.firstPositiveID(row["firstPostId"], row["first_post_id"])
    let firstPostId = first.isEmpty || first == target.threadId ? nil : first
    // A reply-shaped row needs its own topic-level first-post evidence.
    if target.kind == .reply, firstPostId == nil { return nil }
    return AgreeTarget(threadId: target.threadId, firstPostId: firstPostId, replyAnchor: target.postId)
  }

  struct FeedbackTarget: Sendable {
    let threadId: String
    let forumId: String
  }

  static func recommendationFeedback(_ row: [String: Any], personalized: Bool) -> FeedbackTarget? {
    guard personalized, let target = card(row), target.kind == .topic,
          target.threadId == TiebaViewModelMapper.firstPositiveID(row["threadId"], row["thread_id"], row["tid"])
    else { return nil }
    let forumID = row["routingForumId"] as? String ?? TiebaViewModelMapper.routingForumID(row)
    return FeedbackTarget(threadId: target.threadId, forumId: forumID)
  }

  struct ForumTarget: Hashable {
    let id: String
    let name: String

    init?(_ row: [String: Any]) {
      let id = row["routingForumId"] as? String ?? TiebaViewModelMapper.routingForumID(row)
      let name = TiebaViewModelMapper.forumIdentity(row).name
      guard !id.isEmpty || !name.isEmpty else { return nil }
      self.id = id
      self.name = name
    }

    func matches(_ other: Self) -> Bool {
      if !id.isEmpty, !other.id.isEmpty { return id == other.id }
      return !name.isEmpty && name == other.name
    }
  }

  static func forumFeedback(_ row: [String: Any], personalized: Bool) -> FeedbackTarget? {
    guard let feedback = recommendationFeedback(row, personalized: personalized), !feedback.forumId.isEmpty else { return nil }
    return feedback
  }

  private static func personalizedReplyOpening(_ row: [String: Any]) -> Opening? {
    let cardID = TiebaViewModelMapper.firstPositiveID(row["id"])
    let topicID = TiebaViewModelMapper.firstPositiveID(row["threadId"], row["thread_id"], row["tid"])
    let postID = TiebaViewModelMapper.firstPositiveID(row["postId"], row["post_id"])
    let firstPostID = TiebaViewModelMapper.firstPositiveID(row["firstPostId"], row["first_post_id"])
    guard !isShare(row), !postID.isEmpty, !cardID.isEmpty, cardID == topicID,
          firstPostID.isEmpty else { return nil }
    guard let origin = TiebaViewModelMapper.originThreadInfo(row) else {
      return outerReplyOpening(topicID: topicID, postID: postID, reason: .missingOrigin)
    }
    let originPID = TiebaViewModelMapper.firstPositiveID(origin["pid"])
    guard originPID.isEmpty || originPID == postID else {
      return outerReplyOpening(topicID: topicID, postID: postID, reason: .differentOriginPID)
    }

    // Personalized reply cards can repeat the card identity as threadId.
    // The caller must verify that the origin topic actually contains postId.
    let originID = TiebaViewModelMapper.firstPositiveID(origin["threadId"], origin["thread_id"], origin["tid"])
    guard !originID.isEmpty, originID != postID else {
      return Opening(target: nil, rule: .invalidPersonalizedOrigin)
    }
    return Opening(target: target(kind: .reply, id: originID, postId: postID, row: origin), rule: .personalizedOrigin)
  }

  private static func outerReplyOpening(
    topicID: String, postID: String, reason: Opening.Rule.OuterReason
  ) -> Opening {
    guard topicID != postID else { return Opening(target: nil, rule: .invalidPersonalizedOuter) }
    // The card alone does not tie its forum or the nested PID to this topic.
    let candidate = Self(kind: .reply, threadId: topicID, postId: postID, forumId: nil, forumName: nil)
    return Opening(target: candidate, rule: .personalizedOuter(reason))
  }

  struct VerificationGate {
    struct Ticket: Equatable, Sendable {
      fileprivate let generation: UInt64
      let accountKey: String
    }

    private var generation: UInt64 = 0
    private var pending: Ticket?

    mutating func begin(accountKey: String) -> Ticket {
      generation &+= 1
      let ticket = Ticket(generation: generation, accountKey: accountKey)
      pending = ticket
      return ticket
    }

    mutating func cancel() { pending = nil }

    /// nil means a later tap or cancellation owns the UI. false consumes an invalidated attempt.
    mutating func finish(_ ticket: Ticket, accountKey: String, invalidated: Bool, isVisible: Bool) -> Bool? {
      guard pending == ticket else { return nil }
      pending = nil
      return !invalidated && isVisible && accountKey == ticket.accountKey
    }
  }

  static func card(_ row: [String: Any], allowLegacyTopicID: Bool = false) -> Self? {
    let topicID = TiebaViewModelMapper.firstPositiveID(row["threadId"], row["thread_id"], row["tid"])
    let cardID = TiebaViewModelMapper.firstPositiveID(row["id"])
    let firstPostID = TiebaViewModelMapper.firstPositiveID(row["firstPostId"], row["first_post_id"])
    let postID = TiebaViewModelMapper.firstPositiveID(row["postId"], row["post_id"])
    if isShare(row) { return quoted(row) }

    let replyID = postID == firstPostID ? "" : postID
    let origin = quoted(row)
    let nested = TiebaViewModelMapper.originThreadInfo(row)
    let originPID = TiebaViewModelMapper.firstPositiveID(nested?["pid"])
    // A nested tid/pid pair can recover the topic when it identifies the
    // current reply. Neither that reply's PID nor the known first-floor PID is a KZ.
    let identifiableReply = replyID.isEmpty && cardID != firstPostID ? cardID : replyID
    if let origin, !originPID.isEmpty, originPID == identifiableReply {
      if origin.threadId != originPID, origin.threadId != firstPostID {
        guard topicID.isEmpty || topicID == originPID || topicID == firstPostID || topicID == origin.threadId else {
          return nil
        }
        return target(
          kind: .reply, id: origin.threadId, postId: originPID,
          row: topicID == origin.threadId ? row : (nested ?? [:]), matchingOrigin: origin
        )
      }
      // Only an independently identified reply can continue with the top-level KZ.
      guard !replyID.isEmpty else { return nil }
    }

    if !topicID.isEmpty, topicID != replyID {
      if !replyID.isEmpty {
        guard topicID != firstPostID else { return nil }
        return target(kind: .reply, id: topicID, postId: replyID, row: row, matchingOrigin: origin)
      }
      if nested != nil, origin?.threadId != topicID, postID.isEmpty, topicID == cardID {
        return origin
      }
      return target(kind: .topic, id: topicID, postId: nil, row: row, matchingOrigin: origin)
    }

    guard replyID.isEmpty else { return nil }
    if nested != nil { return origin }
    let hasFirstPostIdentity = !postID.isEmpty && postID == firstPostID
    guard allowLegacyTopicID || hasFirstPostIdentity, !cardID.isEmpty, cardID != firstPostID else { return nil }
    return target(kind: .topic, id: cardID, postId: nil, row: row)
  }

  static func quoted(_ row: [String: Any]) -> Self? {
    guard let origin = TiebaViewModelMapper.originThreadInfo(row) else { return nil }
    let id = TiebaViewModelMapper.firstPositiveID(origin["threadId"], origin["thread_id"], origin["tid"])
    guard !id.isEmpty else { return nil }
    return target(kind: .reference, id: id, postId: nil, row: origin)
  }

  /// Legacy outer-card coordinate projection. Feed writes resolve their own targets.
  static func interaction(_ row: [String: Any]) -> Self? {
    if isShare(row) {
      let id = TiebaViewModelMapper.firstPositiveID(row["threadId"], row["thread_id"], row["tid"])
      let post = TiebaViewModelMapper.firstPositiveID(row["postId"], row["post_id"])
      let first = TiebaViewModelMapper.firstPositiveID(row["firstPostId"], row["first_post_id"])
      guard !id.isEmpty, id != post || post == first else { return nil }
      return target(kind: .topic, id: id, postId: nil, row: row)
    }
    guard let result = card(row), result.kind != .reference else { return nil }
    return result
  }

  static func explicit(threadId: String, postId: String? = nil, forumId: String? = nil, forumName: String? = nil) -> Self? {
    guard let thread = TiebaRoutePath.positiveID(threadId) else { return nil }
    let post = TiebaRoutePath.positiveID(postId)
    let anchor = post == thread ? nil : post
    return Self(
      kind: anchor == nil ? .topic : .reply, threadId: String(thread),
      postId: anchor.map { String($0) }, forumId: TiebaRoutePath.positiveID(forumId).map { String($0) },
      forumName: forumName.flatMap { $0.isEmpty ? nil : $0 }
    )
  }

  private static func isShare(_ row: [String: Any]) -> Bool {
    if row["isShareThread"] as? Bool == true { return true }
    return TiebaViewModelMapper.firstPositiveID(row["isShareThread"], row["is_share_thread"]) == "1"
  }

  private static func target(
    kind: Kind, id: String, postId: String?, row: [String: Any], matchingOrigin: Self? = nil
  ) -> Self {
    let forum = TiebaViewModelMapper.forumIdentity(row)
    let origin = matchingOrigin.flatMap { $0.threadId == id ? $0 : nil }
    let rowForumID = row["routingForumId"] as? String ?? TiebaViewModelMapper.routingForumID(row)
    // Use an origin bound to this KZ to fill a missing FID. For reply routes,
    // conflicting valid FIDs for the same KZ are inconclusive.
    let useRowName = origin?.forumId == nil || origin?.forumId == forum.id || forum.id.isEmpty
    let nameMatches = origin?.forumName == nil || forum.name.isEmpty || origin?.forumName == forum.name
    let conflictingReplyForum = kind == .reply && !rowForumID.isEmpty
      && origin?.forumId.map { $0 != rowForumID } == true
    return Self(
      kind: kind, threadId: id, postId: postId,
      forumId: conflictingReplyForum ? nil : (
        origin?.forumId ?? (nameMatches && !rowForumID.isEmpty ? rowForumID : nil)
      ),
      forumName: origin?.forumName ?? (useRowName && !forum.name.isEmpty ? forum.name : nil)
    )
  }
}

/// The optimistic state is separate from the server rows. Dropping a failed
/// operation reveals the latest server values, including after a feed refresh.
struct TiebaFeedAgreeState {
  struct Ticket: Equatable {
    let threadId: String
    let replyAnchor: String?
    let account: String
    let desired: Bool
    fileprivate let serial: UInt64
  }

  struct Count: Equatable {
    let liked: Bool
    let count: Double

    func setting(_ desired: Bool) -> Count {
      guard liked != desired else { return self }
      return Count(liked: desired, count: max(0, count + (desired ? 1 : -1)))
    }
  }

  private var pending: [String: Ticket] = [:]
  private var serial: UInt64 = 0
  var isEmpty: Bool { pending.isEmpty }

  mutating func begin(target: TiebaThreadCardTarget.AgreeTarget, account: String, desired: Bool) -> Ticket? {
    guard pending[target.threadId]?.account != account else { return nil }
    serial &+= 1
    let ticket = Ticket(threadId: target.threadId, replyAnchor: target.replyAnchor, account: account, desired: desired, serial: serial)
    pending[target.threadId] = ticket
    return ticket
  }

  func desired(for target: TiebaThreadCardTarget.AgreeTarget, account: String) -> Bool? {
    guard let ticket = pending[target.threadId], ticket.account == account, ticket.replyAnchor == target.replyAnchor else { return nil }
    return ticket.desired
  }

  mutating func finish(_ ticket: Ticket) -> Bool {
    guard pending[ticket.threadId] == ticket else { return false }
    pending.removeValue(forKey: ticket.threadId)
    return true
  }
}
