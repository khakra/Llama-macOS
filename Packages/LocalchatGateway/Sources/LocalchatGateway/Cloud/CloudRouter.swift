// FORK: localchat gateway.
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// The cloud providers the gateway currently routes to. Set by the app whenever
/// keys or settings change; read on every request.
final class CloudProviders: @unchecked Sendable {
  private let lock = NSLock()
  private var byID: [String: CloudProvider] = [:]

  var all: [CloudProvider] { lock.withLock { Array(byID.values).sorted { $0.displayName < $1.displayName } } }
  func provider(_ id: String) -> CloudProvider? { lock.withLock { byID[id] } }
  func replace(_ providers: [CloudProvider]) {
    lock.withLock { byID = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }) }
  }
}

/// Handles everything that involves a cloud model. Returns nil for requests
/// that are purely local, which then pass through to the engine.
struct CloudRouter: Sendable {
  let providers: CloudProviders
  let catalog: CloudCatalog
  let access: CloudAccessPolicy
  let session: URLSession

  static let streamingSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.timeoutIntervalForRequest = 5 * 60  // longest silence (slow reasoning) before giving up
    configuration.timeoutIntervalForResource = 60 * 60
    return URLSession(configuration: configuration)
  }()

  /// The cloud models to list, with their details. Empty for clients that may not use them.
  func listedModels() async -> [(data: [String: Any], details: [String: Any])] {
    var entries: [(data: [String: Any], details: [String: Any])] = []
    for provider in providers.all where !provider.models.isEmpty {
      let known = await catalog.models(for: provider)
      for model in provider.models {
        let info = known[model] ?? CloudModelInfo.guess(provider: provider.id, model: model)
        entries.append(
          CloudSynthesis.modelEntries(
            id: CloudModelID.make(provider: provider.id, model: model), provider: provider, info: info))
      }
    }
    return entries
  }

  func resolve(_ id: String) -> (CloudProvider, String)? {
    guard let (providerID, model) = CloudModelID.parse(id), let provider = providers.provider(providerID),
      provider.models.contains(model)
    else { return nil }
    return (provider, model)
  }

  // MARK: - Routes

  /// `/props?model=<cloud id>`.
  func props(modelID: String) async -> Response {
    guard let (provider, model) = resolve(modelID) else { return .unknownCloudModel(modelID) }
    let info = await catalog.info(provider: provider, model: model)
    return .json(CloudSynthesis.props(info: info))
  }

  /// `/v1/chat/completions` for a cloud model.
  func chat(body: [String: Any], modelID: String) async -> Response {
    guard let (provider, model) = resolve(modelID) else { return .unknownCloudModel(modelID) }
    let info = await catalog.info(provider: provider, model: model)
    let stream = (body["stream"] as? Bool) ?? false
    let payload = RequestSanitizer.sanitize(body, provider: provider, model: model, info: info)

    var request = URLRequest(url: provider.url("chat/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
    for (name, value) in provider.requestHeaders { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload, options: .withoutEscapingSlashes)

    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await session.bytes(for: request)
    } catch {
      return .jsonError(
        .badGateway, type: "upstream_error",
        message: CloudError.unreachable(provider.displayName, error.localizedDescription).localizedDescription)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 502

    guard (200..<300).contains(status) else {
      var data = Data()
      do {
        for try await byte in bytes {
          data.append(byte)
          if data.count > 1_000_000 { break }
        }
      } catch {}
      bytes.task.cancel()
      let message = CloudError.http(provider.displayName, status, CloudError.message(from: data)).localizedDescription
      return .jsonError(HTTPResponse.Status(code: status), type: "upstream_error", message: message)
    }

    guard stream else {
      var data = Data()
      do {
        for try await byte in bytes { data.append(byte) }
      } catch {
        return .jsonError(.badGateway, type: "upstream_error", message: "\(provider.displayName) stopped responding.")
      }
      guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return .jsonError(.badGateway, type: "upstream_error", message: CloudError.unexpected(provider.displayName).localizedDescription)
      }
      return .json(StreamRewriter.rewriteChunk(object, modelID: modelID))
    }

    return Response(
      status: .ok,
      headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
      body: ResponseBody { writer in
        // Stop the provider (and its billing) as soon as the client goes away.
        defer { bytes.task.cancel() }
        var rewriter = StreamRewriter(modelID: modelID)
        do {
          for try await line in bytes.lines {
            if let out = rewriter.rewrite(line: line) {
              try await writer.write(ByteBuffer(string: out))
            }
          }
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
          throw error
        } catch {
          let message = "\(provider.displayName) stream failed: \(error.localizedDescription)"
          let errorChunk = ["error": ["message": message, "type": "upstream_error"]]
          if let data = try? JSONSerialization.data(withJSONObject: errorChunk, options: .withoutEscapingSlashes), let text = String(data: data, encoding: .utf8) {
            try await writer.write(ByteBuffer(string: "data: \(text)\n\n"))
          }
        }
        if !rewriter.sawDone {
          try await writer.write(ByteBuffer(string: "data: [DONE]\n\n"))
        }
        try await writer.finish(nil)
      })
  }
}

extension Response {
  static func json(_ object: [String: Any], status: HTTPResponse.Status = .ok) -> Response {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes)) ?? Data("{}".utf8)
    return Response(
      status: status, headers: [.contentType: "application/json"],
      body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
  }

  static func unknownCloudModel(_ id: String) -> Response {
    jsonError(
      .notFound, type: "invalid_request_error",
      message: "Cloud model \(id) isn't enabled. Choose it in Settings › Cloud.")
  }

  static var cloudForbidden: Response {
    jsonError(
      .forbidden, type: "forbidden",
      message: "Cloud models can only be used from this Mac, through LocalChat's own page.")
  }

  static func cloudUnsupported(_ path: String) -> Response {
    jsonError(
      .badRequest, type: "invalid_request_error",
      message: "Cloud models support /v1/chat/completions only, not \(path).")
  }
}
