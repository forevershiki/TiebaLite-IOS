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

  /// Card actions act on the outer repost. Opening the card follows its reference.
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
