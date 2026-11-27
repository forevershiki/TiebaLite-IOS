import Foundation
import SQLite3

struct TiebaPrivateMessageCacheChange: Equatable, Sendable {
  let scope: TiebaPrivateMessageScope
  let insertedMessageIDs: [Int64]
  let affectedPeerIDs: Set<Int64>
}

struct TiebaPrivateMessageHistoryCursor: Equatable, Sendable {
  let createdAt: Int64
  let messageID: Int64
}

struct TiebaPrivateMessageConversation: Equatable, Sendable {
  let peerID: Int64
  let latest: TiebaPrivateIncomingMessage
  let localUnreadCount: Int
}

/// A cache of observed incoming messages. Opening this cache or reading a page
/// has no server side effect. Consumers must discard it on account changes.
actor TiebaPrivateMessageCache {
  let scope: TiebaPrivateMessageScope
  private let accountDirectory: URL
  private var closed = false

  init(scope: TiebaPrivateMessageScope, baseDirectory: URL) {
    self.scope = scope
    accountDirectory = baseDirectory.appendingPathComponent(String(scope.accountID), isDirectory: true)
  }

  static func live(scope: TiebaPrivateMessageScope) -> TiebaPrivateMessageCache {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return TiebaPrivateMessageCache(
      scope: scope, baseDirectory: support.appendingPathComponent("TiebaPrivateMessages", isDirectory: true)
    )
  }

  func store(_ batch: TiebaPrivateMessageBatch) throws -> TiebaPrivateMessageCacheChange {
    guard batch.scope == scope else { throw TiebaPrivateMessageError.invalidIdentity }
    return try withDatabase { db in
      try execute(db, "BEGIN IMMEDIATE;")
      var committed = false
      defer {
        if !committed { _ = TiebaSQLiteCore.executeScript(db, "ROLLBACK;") }
      }
      guard let statement = TiebaSQLiteCore.prepare(db, Self.insertSQL) else {
        throw TiebaPrivateMessageError.cacheUnavailable
      }
      defer { sqlite3_finalize(statement) }
      var inserted: [Int64] = []
      var peers: Set<Int64> = []
      for message in batch.incoming {
        guard message.id > 0, message.createdAt > 0, message.senderID > 0,
          message.senderID != scope.accountID else { throw TiebaPrivateMessageError.invalidIdentity }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bind(group: scope.groupID, to: statement)
        try requireOK(sqlite3_bind_int64(statement, 2, message.id))
        try requireOK(sqlite3_bind_int64(statement, 3, message.senderID))
        try requireOK(sqlite3_bind_int64(statement, 4, message.createdAt))
        switch message.content {
        case .text(let text):
          try requireOK(sqlite3_bind_int(statement, 5, 1))
          // Length is explicit so a Unicode string containing U+0000 round trips.
          guard let length = Int32(exactly: text.utf8.count) else {
            throw TiebaPrivateMessageError.malformedPayload
          }
          try requireOK(text.withCString { sqlite3_bind_text(statement, 6, $0, length, TiebaSQLiteCore.transient()) })
        case .unsupported(let wireType):
          guard wireType != 1 else { throw TiebaPrivateMessageError.malformedPayload }
          try requireOK(sqlite3_bind_int(statement, 5, wireType))
          try requireOK(sqlite3_bind_null(statement, 6))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TiebaPrivateMessageError.cacheUnavailable }
        if sqlite3_changes(db) > 0 {
          inserted.append(message.id)
          peers.insert(message.senderID)
        }
      }
      try execute(db, "COMMIT;")
      committed = true
      return .init(scope: scope, insertedMessageIDs: inserted, affectedPeerIDs: peers)
    }
  }

  func conversations() throws -> [TiebaPrivateMessageConversation] {
    try withDatabase { db in
      guard let statement = TiebaSQLiteCore.prepare(db, Self.conversationsSQL) else {
        throw TiebaPrivateMessageError.cacheUnavailable
      }
      defer { sqlite3_finalize(statement) }
      try bind(group: scope.groupID, to: statement)
      return try rows(statement) { row in
        let message = try decode(row)
        return .init(peerID: message.senderID, latest: message, localUnreadCount: Int(sqlite3_column_int64(row, 5)))
      }
    }
  }

  func history(
    peerID: Int64, before: TiebaPrivateMessageHistoryCursor? = nil, limit: Int = 40
  ) throws -> (messages: [TiebaPrivateIncomingMessage], next: TiebaPrivateMessageHistoryCursor?) {
    try requirePeer(peerID)
    let size = min(max(limit, 1), 100)
    return try withDatabase { db in
      guard let statement = TiebaSQLiteCore.prepare(db, Self.historySQL) else {
        throw TiebaPrivateMessageError.cacheUnavailable
      }
      defer { sqlite3_finalize(statement) }
      try bind(group: scope.groupID, to: statement)
      try requireOK(sqlite3_bind_int64(statement, 2, peerID))
      try requireOK(sqlite3_bind_int64(statement, 3, before?.createdAt ?? Int64.max))
      try requireOK(sqlite3_bind_int64(statement, 4, before?.messageID ?? Int64.max))
      try requireOK(sqlite3_bind_int64(statement, 5, Int64(size + 1)))
      let items = try rows(statement, decode)
      let page = Array(items.prefix(size))
      let next = items.count > size ? page.last.map {
        TiebaPrivateMessageHistoryCursor(createdAt: $0.createdAt, messageID: $0.id)
      } : nil
      return (page, next)
    }
  }

  /// This advances only the local read watermark, through a known message in
  /// the currently viewed conversation. It is independent of peer receipts.
  @discardableResult
  func markLocalRead(peerID: Int64, through messageID: Int64) throws -> Bool {
    try requirePeer(peerID)
    guard messageID > 0 else { throw TiebaPrivateMessageError.invalidIdentity }
    return try withDatabase { db in
      guard let statement = TiebaSQLiteCore.prepare(db, Self.readSQL) else {
        throw TiebaPrivateMessageError.cacheUnavailable
      }
      defer { sqlite3_finalize(statement) }
      try bind(group: scope.groupID, to: statement)
      try requireOK(sqlite3_bind_int64(statement, 2, peerID))
      try requireOK(sqlite3_bind_int64(statement, 3, messageID))
      guard sqlite3_step(statement) == SQLITE_DONE else { throw TiebaPrivateMessageError.cacheUnavailable }
      return sqlite3_changes(db) > 0
    }
  }

  func close() { closed = true }

  /// Clears only this account's cache files. Call after closing any consumers
  /// of the same account. Existing handles from this store cannot reopen it.
  func clear() throws {
    closed = true
    do {
      try FileManager.default.removeItem(at: accountDirectory)
    } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
      return
    } catch {
      throw TiebaPrivateMessageError.cacheUnavailable
    }
  }

  private func withDatabase<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
    guard !closed else { throw TiebaPrivateMessageError.cacheUnavailable }
    let db: OpaquePointer
    do {
      let file = try protectedFile()
      db = try TiebaSQLiteCore.open(path: file.path, profile: .relational)
    } catch {
      throw TiebaPrivateMessageError.cacheUnavailable
    }
    defer { sqlite3_close_v2(db) }
    try migrate(db)
    return try operation(db)
  }

  private func protectedFile() throws -> URL {
    let manager = FileManager.default
    let file = accountDirectory.appendingPathComponent("inbox.sqlite3")
    try manager.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
    #if os(iOS)
    let protection = [FileAttributeKey.protectionKey: FileProtectionType.complete]
    try manager.setAttributes(protection, ofItemAtPath: accountDirectory.path)
    var directory = accountDirectory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    if !manager.fileExists(atPath: file.path) {
      do {
        try Data().write(to: file, options: [.withoutOverwriting, .completeFileProtection])
      } catch let error as CocoaError where error.code == .fileWriteFileExists {
        // Another instance created it between the check and exclusive write.
      }
    }
    try manager.setAttributes(protection, ofItemAtPath: file.path)
    #endif
    return file
  }

  private func migrate(_ db: OpaquePointer) throws {
    func version() throws -> Int32 {
      guard let statement = TiebaSQLiteCore.prepare(db, "PRAGMA user_version;") else {
        throw TiebaPrivateMessageError.cacheUnavailable
      }
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { throw TiebaPrivateMessageError.cacheUnavailable }
      return sqlite3_column_int(statement, 0)
    }
    let current = try version()
    guard current == 0 || current == 1 else { throw TiebaPrivateMessageError.cacheUnavailable }
    guard current == 0 else { return }
    try execute(db, "BEGIN IMMEDIATE;")
    do {
      let locked = try version()
      guard locked == 0 || locked == 1 else { throw TiebaPrivateMessageError.cacheUnavailable }
      if locked == 0 { try execute(db, Self.schemaSQL) }
      try execute(db, "COMMIT;")
    } catch {
      _ = TiebaSQLiteCore.executeScript(db, "ROLLBACK;")
      throw error
    }
  }

  private func requirePeer(_ id: Int64) throws {
    guard id > 0, id != scope.accountID else { throw TiebaPrivateMessageError.invalidIdentity }
  }

  private func bind(group: Int64, to statement: OpaquePointer) throws {
    try requireOK(sqlite3_bind_int64(statement, 1, group))
  }

  private func requireOK(_ code: Int32) throws {
    guard code == SQLITE_OK else { throw TiebaPrivateMessageError.cacheUnavailable }
  }

  private func execute(_ db: OpaquePointer, _ sql: String) throws {
    guard TiebaSQLiteCore.executeScript(db, sql) == nil else { throw TiebaPrivateMessageError.cacheUnavailable }
  }

  private func rows<T>(_ statement: OpaquePointer, _ decode: (OpaquePointer) throws -> T) throws -> [T] {
    var result: [T] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      result.append(try decode(statement))
      status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw TiebaPrivateMessageError.cacheUnavailable }
    return result
  }

  private func decode(_ statement: OpaquePointer) throws -> TiebaPrivateIncomingMessage {
    let type = sqlite3_column_int(statement, 3)
    let content: TiebaPrivateIncomingMessage.Content
    if type == 1 {
      guard let text = TiebaSQLiteCore.columnString(statement, 4) else {
        throw TiebaPrivateMessageError.cacheUnavailable
      }
      content = .text(text)
    } else {
      content = .unsupported(wireType: type)
    }
    return .init(
      id: sqlite3_column_int64(statement, 0), senderID: sqlite3_column_int64(statement, 1),
      createdAt: sqlite3_column_int64(statement, 2), content: content
    )
  }

  private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS incoming (
      group_id INTEGER NOT NULL,
      message_id INTEGER NOT NULL,
      sender_id INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      kind INTEGER NOT NULL,
      body TEXT,
      PRIMARY KEY (group_id, message_id)
    );
    CREATE INDEX IF NOT EXISTS incoming_history
      ON incoming (group_id, sender_id, created_at DESC, message_id DESC);
    CREATE TABLE IF NOT EXISTS local_read (
      group_id INTEGER NOT NULL,
      peer_id INTEGER NOT NULL,
      through_id INTEGER NOT NULL,
      PRIMARY KEY (group_id, peer_id)
    );
    PRAGMA user_version = 1;
    """

  private static let insertSQL = """
    INSERT INTO incoming (group_id, message_id, sender_id, created_at, kind, body)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6)
    ON CONFLICT (group_id, message_id) DO NOTHING;
    """

  private static let historySQL = """
    SELECT message_id, sender_id, created_at, kind, body FROM incoming
    WHERE group_id = ?1 AND sender_id = ?2 AND (created_at, message_id) < (?3, ?4)
    ORDER BY created_at DESC, message_id DESC LIMIT ?5;
    """

  private static let conversationsSQL = """
    WITH ranked AS (
      SELECT message_id, sender_id, created_at, kind, body,
        ROW_NUMBER() OVER (PARTITION BY sender_id ORDER BY created_at DESC, message_id DESC) AS row_number,
        COUNT(CASE WHEN message_id > COALESCE(through_id, 0) THEN 1 END)
          OVER (PARTITION BY sender_id) AS unread
      FROM incoming LEFT JOIN local_read
        ON local_read.group_id = incoming.group_id AND peer_id = sender_id
      WHERE incoming.group_id = ?1
    )
    SELECT message_id, sender_id, created_at, kind, body, unread FROM ranked
    WHERE row_number = 1 ORDER BY created_at DESC, message_id DESC;
    """

  private static let readSQL = """
    INSERT INTO local_read (group_id, peer_id, through_id) SELECT ?1, ?2, ?3
    WHERE EXISTS (SELECT 1 FROM incoming WHERE group_id = ?1 AND sender_id = ?2 AND message_id = ?3)
    ON CONFLICT (group_id, peer_id) DO UPDATE SET through_id = excluded.through_id
    WHERE excluded.through_id > local_read.through_id;
    """
}
