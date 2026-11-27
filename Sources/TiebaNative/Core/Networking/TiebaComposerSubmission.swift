import Foundation

struct TiebaComposerIdentity: Sendable {
  let uid: String
  let bduss: String
  let stoken: String
  let nickname: String

  var isValid: Bool {
    TiebaComposerTarget.isPositiveID(uid) && [bduss, stoken].allSatisfy { credential in
      !credential.isEmpty && credential.utf8.allSatisfy {
        (33...126).contains($0) && ![34, 44, 59, 92].contains($0)
      }
    }
  }
}

enum TiebaComposerProgress: Equatable {
  case uploading(Int, Int)
  case preparing
  case sending
}

struct TiebaComposerTransport {
  typealias Form = @Sendable (URL, [String: String], String) async throws -> (status: Int, data: Data)
  let send: Form
  let signLogin: @Sendable ([String: String]) -> String
  let now: @Sendable () -> Int64
}

@MainActor
final class TiebaComposerSubmission {
  private let transport: TiebaComposerTransport
  private var isSending = false

  init(transport: TiebaComposerTransport) {
    self.transport = transport
  }

  func submit(
    target: TiebaComposerTarget, draft: TiebaComposerDraft, identity: TiebaComposerIdentity?,
    validateSession: () throws -> Void,
    willSend: () throws -> Void,
    progress: (TiebaComposerProgress) -> Void
  ) async throws -> TiebaComposerReceipt {
    guard !isSending else { throw TiebaComposerFailure.busy }
    guard let identity, identity.isValid else { throw TiebaComposerFailure.login }
    try draft.validate(for: target)
    guard !draft.outcomeUnknown else { throw TiebaComposerFailure.unknown }
    try validateSession()
    isSending = true
    defer { isSending = false }

    let headers = Self.headers(identity: identity, target: target)
    let uploadInfo = try await upload(draft.images, headers: headers, validateSession: validateSession, progress: progress)
    progress(.preparing)
    let tbs = try await fetchTBS(identity: identity)
    try validateSession()
    if Task.isCancelled { throw TiebaComposerFailure.cancelled }

    let timestamp = String(transport.now())
    let path = target.showsTitle ? TiebaComposerProtocol.topicPath : TiebaComposerProtocol.replyPath
    let url = Self.url(path, query: target.showsTitle ? [] : [.init(name: "_t", value: timestamp)])
    let fields = try TiebaComposerProtocol.fields(
      target: target, draft: draft, tbs: tbs, nickname: identity.nickname,
      timestamp: timestamp, imageInfo: uploadInfo
    )
    let body = TiebaComposerProtocol.form(fields)
    try willSend()
    progress(.sending)
    let response: (status: Int, data: Data)
    do {
      response = try await transport.send(url, headers, body)
    } catch {
      throw TiebaComposerFailure.unknown
    }
    return try TiebaComposerProtocol.receipt(status: response.status, data: response.data, target: target)
  }

  private func upload(
    _ images: [Data], headers: [String: String], validateSession: () throws -> Void,
    progress: (TiebaComposerProgress) -> Void
  ) async throws -> [String] {
    var uploaded: [String] = []
    for (index, data) in images.enumerated() {
      try validateSession()
      if Task.isCancelled { throw TiebaComposerFailure.cancelled }
      progress(.uploading(index + 1, images.count))
      let url = Self.url(TiebaComposerProtocol.uploadPath, query: [
        .init(name: "type", value: "ajax"), .init(name: "r", value: "\(transport.now())_\(index)"),
      ])
      do {
        let response = try await transport.send(
          url, headers, TiebaComposerProtocol.form(["pic": data.base64EncodedString()])
        )
        uploaded.append(try TiebaComposerProtocol.uploadedImage(status: response.status, data: response.data))
      } catch where Task.isCancelled {
        throw TiebaComposerFailure.cancelled
      } catch let failure as TiebaComposerFailure {
        throw failure == .unknown ? .upload : failure
      } catch {
        throw TiebaComposerFailure.upload
      }
    }
    return uploaded
  }

  private func fetchTBS(identity: TiebaComposerIdentity) async throws -> String {
    if Task.isCancelled { throw TiebaComposerFailure.cancelled }
    let version = "22.5.1.0"
    var fields = ["_client_version": version, "bdusstoken": identity.bduss]
    fields["sign"] = transport.signLogin(fields)
    do {
      let response = try await transport.send(
        URL(string: "https://tiebac.baidu.com/c/s/login")!,
        ["User-Agent": "tieba/\(version) skin/default"], TiebaComposerProtocol.form(fields)
      )
      return try TiebaComposerProtocol.postingTBS(status: response.status, data: response.data, accountID: identity.uid)
    } catch where Task.isCancelled {
      throw TiebaComposerFailure.cancelled
    } catch let failure as TiebaComposerFailure {
      throw failure == .unknown ? .preparation : failure
    } catch {
      throw TiebaComposerFailure.preparation
    }
  }

  private static func headers(identity: TiebaComposerIdentity, target: TiebaComposerTarget) -> [String: String] {
    let referer: String
    if let thread = target.threadID {
      referer = "\(TiebaComposerProtocol.host)/p/\(thread)?lp=5028&mo_device=1&is_jingpost=0&pn=1&"
    } else {
      referer = url("/f", query: [.init(name: "kw", value: target.forum.name)]).absoluteString
    }
    return [
      "Accept": "application/json, text/plain, */*", "Accept-Language": "zh-CN,zh;q=0.9",
      "Origin": TiebaComposerProtocol.host, "Referer": referer, "X-Requested-With": "XMLHttpRequest",
      "Cache-Control": "no-cache", "Pragma": "no-cache",
      "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
      "Cookie": "BDUSS=\(identity.bduss); STOKEN=\(identity.stoken)",
    ]
  }

  private static func url(_ path: String, query: [URLQueryItem]) -> URL {
    var components = URLComponents(string: TiebaComposerProtocol.host)!
    components.path = path
    if !query.isEmpty { components.queryItems = query }
    return components.url!
  }
}
