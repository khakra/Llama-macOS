// FORK: localchat gateway.
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Where the `llama serve` engine listens. Read per request, so an engine
/// restart on a new port needs no gateway restart.
public struct EngineEndpoint: Sendable, Equatable {
  public var host: String
  public var port: Int

  public init(host: String = "127.0.0.1", port: Int) {
    self.host = host
    self.port = port
  }
}

/// Passes a request through to the engine unchanged and streams the answer back.
///
/// Response bodies stream chunk by chunk, so SSE (chat tokens, `/models/sse`)
/// arrives as it's produced. When the client goes away, writing fails, the body
/// stream ends and the upstream request is cancelled, so the engine stops generating.
struct EngineProxy: Sendable {
  let engine: @Sendable () -> EngineEndpoint?

  /// Request bodies are collected before sending: they're JSON, with images
  /// inlined at most, and a known length keeps the upstream request simple.
  static let maxRequestBody = 512 * 1024 * 1024

  /// Connection-level headers (RFC 9110 7.6.1), and ones the upstream client sets itself.
  static let requestHeadersToDrop: Set<String> = [
    "connection", "keep-alive", "proxy-connection", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length",
  ]
  static let responseHeadersToDrop: Set<String> = [
    "connection", "keep-alive", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade",
    "content-length",
  ]

  /// Forwards `request`. Pass `body` when the caller already read it (to look at the model).
  func forward(_ request: Request, body collected: ByteBuffer? = nil) async -> Response {
    guard let endpoint = engine() else { return .engineUnavailable }

    let body: ByteBuffer
    if let collected {
      body = collected
    } else {
      do {
        body = try await request.body.collect(upTo: Self.maxRequestBody)
      } catch {
        return .jsonError(.contentTooLarge, type: "invalid_request_error", message: "Request body too large.")
      }
    }

    var forwardedHeaders: [(String, String)] = []
    for field in request.headers
    where !Self.requestHeadersToDrop.contains(field.name.canonicalName) {
      forwardedHeaders.append((field.name.rawName, field.value))
    }

    let head: UpstreamClient.Head
    let chunks: AsyncThrowingStream<ByteBuffer, Error>
    do {
      (head, chunks) = try await UpstreamClient.send(
        host: endpoint.host, port: endpoint.port, method: request.method.rawValue,
        path: request.head.path ?? "/", headers: forwardedHeaders, body: body)
    } catch {
      // Nothing listening (engine starting, restarting or crashed).
      return .engineUnavailable
    }

    var headers = HTTPFields()
    var contentLength: Int?
    for (name, value) in head.headers {
      let lowered = name.lowercased()
      if lowered == "content-length" { contentLength = Int(value) }
      guard !Self.responseHeadersToDrop.contains(lowered), let fieldName = HTTPField.Name(name) else {
        continue
      }
      headers.append(HTTPField(name: fieldName, value: value))
    }

    return Response(
      status: HTTPResponse.Status(code: head.status),
      headers: headers,
      body: ResponseBody(contentLength: contentLength) { writer in
        for try await chunk in chunks {
          try await writer.write(chunk)
        }
        try await writer.finish(nil)
      }
    )
  }
}

extension EngineProxy {
  /// GET `path` from the engine and parse the JSON body. Nil if the engine is
  /// down or answers with an error.
  func fetchJSON(_ path: String, headers: HTTPFields) async -> [String: Any]? {
    guard let endpoint = engine() else { return nil }
    var forwarded: [(String, String)] = []
    for field in headers where field.name == .authorization { forwarded.append((field.name.rawName, field.value)) }
    guard
      let (head, chunks) = try? await UpstreamClient.send(
        host: endpoint.host, port: endpoint.port, method: "GET", path: path, headers: forwarded, body: nil),
      head.status == 200
    else { return nil }
    var buffer = ByteBuffer()
    do {
      for try await chunk in chunks {
        var chunk = chunk
        buffer.writeBuffer(&chunk)
        if buffer.readableBytes > 50_000_000 { return nil }
      }
    } catch { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView))) as? [String: Any]
  }
}

extension Response {
  /// OpenAI-style error body, so clients that read `error.message` show something useful.
  static func jsonError(_ status: HTTPResponse.Status, type: String, message: String) -> Response {
    let payload: [String: Any] = [
      "error": ["code": status.code, "type": type, "message": message]
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: .withoutEscapingSlashes)) ?? Data()
    return Response(
      status: status,
      headers: [.contentType: "application/json"],
      body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
    )
  }

  static var engineUnavailable: Response {
    jsonError(
      .serviceUnavailable, type: "unavailable_error",
      message: "The local engine isn't running yet. Try again in a moment.")
  }

  static var forbiddenHost: Response {
    jsonError(.forbidden, type: "forbidden", message: "Host not allowed.")
  }
}
