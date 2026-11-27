import Foundation

enum TiebaPrivateMessageError: Error, Equatable {
  case loginRequired
  case invalidIdentity
  case unsafeEndpoint
  case unverifiedEndpoint
  case malformedPayload
  case rejected(Int32)
  case cacheUnavailable
}

enum TiebaPrivateMessageAccess {
  // Neither reference establishes an authenticated TLS route for one-to-one IM.
  static let verifiedService: URL? = nil

  static func endpoint(accountID: Int64?, candidate: URL) throws -> URL {
    guard let accountID, accountID > 0 else { throw TiebaPrivateMessageError.loginRequired }
    guard let url = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
      url.scheme == "wss", url.host == "im.tieba.baidu.com",
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
    else { throw TiebaPrivateMessageError.unsafeEndpoint }
    guard let verifiedService, candidate == verifiedService else {
      throw TiebaPrivateMessageError.unverifiedEndpoint
    }
    return candidate
  }
}

struct TiebaPrivateMessageScope: Equatable, Sendable {
  let accountID: Int64
  let groupID: Int64

  init(accountID: Int64, groupID: Int64) throws {
    guard accountID > 0, groupID > 0 else { throw TiebaPrivateMessageError.invalidIdentity }
    self.accountID = accountID
    self.groupID = groupID
  }
}

struct TiebaPrivateIncomingMessage: Equatable, Sendable {
  enum Content: Equatable, Sendable {
    case text(String)
    case unsupported(wireType: Int32)

    var preview: String {
      switch self {
      case .text(let text): text
      case .unsupported: "暂不支持的私信类型"
      }
    }
  }

  let id: Int64
  let senderID: Int64
  let createdAt: Int64
  let content: Content
}

struct TiebaPrivateMessageBatch: Equatable, Sendable {
  struct PeerRead: Equatable, Sendable {
    let peerID: Int64
    let throughID: Int64
  }

  let scope: TiebaPrivateMessageScope
  let incoming: [TiebaPrivateIncomingMessage]
  let peerReads: [PeerRead]
}

struct TiebaPrivateMessagePushHint: Equatable, Hashable, Sendable {
  let messageID: Int64
  let kind: Int32
}

struct TiebaPrivateSendExpectation: Equatable, Sendable {
  let scope: TiebaPrivateMessageScope
  let peerID: Int64
  let recordID: Int64
  let requestID: UInt32

  init(scope: TiebaPrivateMessageScope, peerID: Int64, recordID: Int64, requestID: UInt32) throws {
    guard peerID > 0, peerID != scope.accountID, recordID > 0, requestID > 0 else {
      throw TiebaPrivateMessageError.invalidIdentity
    }
    self.scope = scope
    self.peerID = peerID
    self.recordID = recordID
    self.requestID = requestID
  }
}

/// State for a single explicit send. A disconnected or timed out attempt ends
/// in .unknown and cannot dispatch again. A future transport owns request IDs.
struct TiebaPrivateSendAttempt: Equatable, Sendable {
  enum State: Equatable, Sendable {
    case pending
    case sending
    case confirmed(messageID: Int64)
    case rejected(code: Int32)
    case unknown
  }

  let expectation: TiebaPrivateSendExpectation
  private(set) var state: State = .pending

  mutating func begin() -> Bool {
    guard state == .pending else { return false }
    state = .sending
    return true
  }

  @discardableResult
  mutating func accept(command: UInt32, requestID: UInt32, payload: Data) -> Bool {
    guard state == .sending, command == TiebaPrivateMessageProtocol.sendCommand,
      requestID == expectation.requestID else { return false }
    state = TiebaPrivateMessageProtocol.resolveSend(payload, expectation: expectation)
    return true
  }

  mutating func loseConfirmation() {
    if state == .sending { state = .unknown }
  }
}

/// Passive protobuf decoding only. Inputs are the decoded payload from a future
/// authenticated transport. No framing, credential packing or network I/O.
enum TiebaPrivateMessageProtocol {
  static let groupMessagesCommand: UInt32 = 202003
  static let pushCommand: UInt32 = 202006
  static let sendCommand: UInt32 = 205001

  private static let privateGroup: Int32 = 6

  static func messages(_ payload: Data, scope: TiebaPrivateMessageScope) throws -> TiebaPrivateMessageBatch {
    let envelope = try WireMessage(payload)
    try rejectBusinessError(in: envelope)
    guard let data = try envelope.message(2) else { throw TiebaPrivateMessageError.malformedPayload }
    var incoming: [TiebaPrivateIncomingMessage] = []
    var peerReads: [TiebaPrivateMessageBatch.PeerRead] = []
    for group in try data.messages(1) {
      guard let info = try group.message(1), try info.int32(20) == privateGroup,
        try info.positiveID(1) == scope.groupID else { continue }
      for item in try group.messages(2) {
        guard let sender = try item.message(10)?.positiveID(1), sender != scope.accountID,
          let id = try item.positiveID(1) else { continue }
        let type = try item.int32(3) ?? 0
        if type == 22 {
          if let receipt = try readEvent(item, peerID: sender, groupID: scope.groupID) {
            peerReads.append(receipt)
          }
          continue
        }
        if type == 10 { continue }
        guard let time = try item.int32(8), time > 0 else { continue }
        let content: TiebaPrivateIncomingMessage.Content
        if type == 1 {
          guard let text = try item.string(5), !text.isEmpty else { continue }
          content = .text(text)
        } else {
          content = .unsupported(wireType: type)
        }
        incoming.append(.init(id: id, senderID: sender, createdAt: Int64(time), content: content))
      }
    }
    return TiebaPrivateMessageBatch(scope: scope, incoming: incoming, peerReads: peerReads)
  }

  /// A push is an invalidation hint for the authenticated group, never a message
  /// or an unread count. The caller still needs an authorized group fetch.
  static func pushHints(_ payload: Data, scope: TiebaPrivateMessageScope) throws -> [TiebaPrivateMessagePushHint] {
    var seen: Set<TiebaPrivateMessagePushHint> = []
    return try WireMessage(payload).messages(2).compactMap { wrapper in
      guard let item = try wrapper.message(2), try item.int32(7) == privateGroup,
        try item.positiveID(1) == scope.groupID, let messageID = try item.positiveID(2)
      else { return nil }
      let hint = TiebaPrivateMessagePushHint(messageID: messageID, kind: try item.int32(4) ?? 0)
      return seen.insert(hint).inserted ? hint : nil
    }
  }

  fileprivate static func resolveSend(
    _ payload: Data, expectation: TiebaPrivateSendExpectation
  ) -> TiebaPrivateSendAttempt.State {
    do {
      let envelope = try WireMessage(payload)
      try rejectBusinessError(in: envelope)
      guard let data = try envelope.message(2) else { return .unknown }
      if let block = try data.message(6), let code = try block.int32(1), code != 0 {
        return .rejected(code: code)
      }
      // A missing or contradictory echo is ambiguous. The older C# response
      // projection knows msgId alone. This verifier requires the newer echoes.
      guard let messageID = try data.positiveID(1),
        try data.positiveID(2) == expectation.scope.groupID,
        try data.positiveID(3) == expectation.recordID,
        try data.positiveID(4) == expectation.peerID,
        (try data.int32(5) ?? 0) == 0
      else { return .unknown }
      return .confirmed(messageID: messageID)
    } catch TiebaPrivateMessageError.rejected(let code) {
      return .rejected(code: code)
    } catch {
      return .unknown
    }
  }

  private static func rejectBusinessError(in envelope: WireMessage) throws {
    if let error = try envelope.message(1), let code = try error.int32(1), code != 0 {
      throw TiebaPrivateMessageError.rejected(code)
    }
  }

  private struct ReadEvent: Decodable {
    struct Parameters: Decodable {
      let groupId: Int64
      let readMsgId: Int64
    }
    let eventId: Int
    let eventParam: Parameters
  }

  private static func readEvent(
    _ item: WireMessage, peerID: Int64, groupID: Int64
  ) throws -> TiebaPrivateMessageBatch.PeerRead? {
    guard let text = try item.string(5),
      let event = try? JSONDecoder().decode(ReadEvent.self, from: Data(text.utf8)),
      event.eventId == 22001, event.eventParam.groupId == groupID,
      event.eventParam.readMsgId > 0
    else { return nil }
    return .init(peerID: peerID, throughID: event.eventParam.readMsgId)
  }
}

/// Limited decoder for the four verified proto3 wire scalar types. It preserves
/// int64 IDs exactly, rejects contradictory singular fields and bounds input.
private struct WireMessage {
  private enum Field: Equatable {
    case integer(UInt64)
    case bytes(ArraySlice<UInt8>)
    case fixed32
    case fixed64
  }

  private var fields: [Int: [Field]] = [:]

  init(_ data: Data) throws {
    guard data.count <= 2 * 1024 * 1024 else { throw TiebaPrivateMessageError.malformedPayload }
    try self.init(Array(data)[...])
  }

  private init(_ bytes: ArraySlice<UInt8>) throws {
    var position = bytes.startIndex
    var fieldCount = 0
    while position < bytes.endIndex {
      fieldCount += 1
      guard fieldCount <= 65_536 else { throw TiebaPrivateMessageError.malformedPayload }
      let tag = try Self.varint(bytes, &position)
      let number = Int(tag >> 3)
      guard (1...536_870_911).contains(number) else { throw TiebaPrivateMessageError.malformedPayload }
      let field: Field
      switch tag & 7 {
      case 0: field = .integer(try Self.varint(bytes, &position))
      case 1:
        _ = try Self.take(bytes, &position, length: 8)
        field = .fixed64
      case 2:
        let length = try Self.varint(bytes, &position)
        field = .bytes(try Self.take(bytes, &position, length: length))
      case 5:
        _ = try Self.take(bytes, &position, length: 4)
        field = .fixed32
      default: throw TiebaPrivateMessageError.malformedPayload
      }
      fields[number, default: []].append(field)
    }
  }

  func positiveID(_ number: Int) throws -> Int64? {
    guard let field = try singular(number) else { return nil }
    guard case .integer(let value) = field, let id = Int64(exactly: value), id > 0
    else { throw TiebaPrivateMessageError.malformedPayload }
    return id
  }

  func int32(_ number: Int) throws -> Int32? {
    guard let field = try singular(number) else { return nil }
    guard case .integer(let value) = field else { throw TiebaPrivateMessageError.malformedPayload }
    let signed = Int32(truncatingIfNeeded: value)
    guard UInt64(bitPattern: Int64(signed)) == value else { throw TiebaPrivateMessageError.malformedPayload }
    return signed
  }

  func string(_ number: Int) throws -> String? {
    guard let field = try singular(number) else { return nil }
    guard case .bytes(let bytes) = field, let value = String(bytes: bytes, encoding: .utf8)
    else { throw TiebaPrivateMessageError.malformedPayload }
    return value
  }

  func message(_ number: Int) throws -> WireMessage? {
    guard let field = try singular(number) else { return nil }
    return try Self.decodeMessage(field)
  }

  func messages(_ number: Int) throws -> [WireMessage] {
    try (fields[number] ?? []).map(Self.decodeMessage)
  }

  private func singular(_ number: Int) throws -> Field? {
    guard let items = fields[number], let first = items.first else { return nil }
    guard items.allSatisfy({ $0 == first }) else { throw TiebaPrivateMessageError.malformedPayload }
    return first
  }

  private static func decodeMessage(_ field: Field) throws -> WireMessage {
    guard case .bytes(let bytes) = field else { throw TiebaPrivateMessageError.malformedPayload }
    return try WireMessage(bytes)
  }

  private static func take(
    _ bytes: ArraySlice<UInt8>, _ position: inout Int, length: UInt64
  ) throws -> ArraySlice<UInt8> {
    guard length <= UInt64(bytes.endIndex - position) else { throw TiebaPrivateMessageError.malformedPayload }
    let start = position
    position += Int(length)
    return bytes[start..<position]
  }

  private static func varint(_ bytes: ArraySlice<UInt8>, _ position: inout Int) throws -> UInt64 {
    var result: UInt64 = 0
    for shift in stride(from: 0, through: 63, by: 7) {
      guard position < bytes.endIndex else { break }
      let byte = bytes[position]
      position += 1
      guard shift != 63 || byte <= 1 else { break }
      result |= UInt64(byte & 0x7f) << shift
      if byte < 128 { return result }
    }
    throw TiebaPrivateMessageError.malformedPayload
  }
}
