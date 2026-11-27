/// Resolve feed IDs before constructing a thread route. A card ID identifies a
/// reply on some feeds, so it is only an acceptable topic fallback for topic cards.
struct TiebaThreadCardTarget {
  let threadId: String
  let postId: String?
  let forumId: String?
  let forumName: String?

  func route(fromFavorites: Bool = false) -> TiebaRoute {
    .thread(id: threadId, postId: postId, fromFavorites: fromFavorites, forumId: forumId, forumName: forumName)
  }

  static func card(_ row: [String: Any]) -> Self? {
    let topicID = TiebaViewModelMapper.firstPositiveID(row["threadId"], row["thread_id"], row["tid"])
    let cardID = TiebaViewModelMapper.firstPositiveID(row["id"])
    let firstPostID = TiebaViewModelMapper.firstPositiveID(row["firstPostId"], row["first_post_id"])
    let postID = TiebaViewModelMapper.firstPositiveID(row["postId"], row["post_id"])
    let origin = row["originThreadInfo"] as? [String: Any]
    let isShare = row["isShareThread"] as? Bool == true
    let isReply = !postID.isEmpty && postID != firstPostID && postID != topicID

    if !topicID.isEmpty {
      return target(topicID, postId: isReply && !isShare ? postID : nil, row: row)
    }
    if !isShare, isReply || origin != nil {
      // The card's reply might quote another topic. Only use the origin's
      // own coordinates, without transferring the outer card's reply anchor.
      return quoted(row)
    }
    guard !cardID.isEmpty else { return nil }
    return target(cardID, postId: nil, row: row)
  }

  static func quoted(_ row: [String: Any]) -> Self? {
    guard let origin = row["originThreadInfo"] as? [String: Any] else { return nil }
    let id = TiebaViewModelMapper.firstPositiveID(origin["threadId"], origin["thread_id"], origin["tid"])
    guard !id.isEmpty else { return nil }
    return target(id, postId: nil, row: origin)
  }

  private static func target(_ id: String, postId: String?, row: [String: Any]) -> Self {
    let forum = TiebaViewModelMapper.forumIdentity(row)
    return Self(
      threadId: id, postId: postId,
      forumId: forum.id.isEmpty ? nil : forum.id,
      forumName: forum.name.isEmpty ? nil : forum.name
    )
  }
}
