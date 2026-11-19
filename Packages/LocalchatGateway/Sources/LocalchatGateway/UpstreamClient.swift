// FORK: localchat gateway.
import NIOCore
import NIOHTTP1
import NIOPosix

/// A minimal HTTP/1.1 client for talking to the engine on loopback, built on
/// SwiftNIO (already in the app through Hummingbird, so it adds no size).
///
/// Not URLSession: it holds back the start of a text response until it has
/// sniffed ~512 bytes, so a quiet SSE feed (`/models/sse`) never delivers its
/// headers and small events arrive late. Not AsyncHTTPClient: it brings TLS and
/// HTTP/2 we don't need on loopback (~30 MB of binary).
///
/// One connection per request, closed when the response ends or the caller stops reading.
enum UpstreamClient {
  struct Head: Sendable {
    let status: Int
    let headers: [(String, String)]
  }

  static func send(
    host: String, port: Int, method: String, path: String, headers: [(String, String)],
    body: ByteBuffer?
  ) async throws -> (Head, AsyncThrowingStream<ByteBuffer, Error>) {
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .connectTimeout(.seconds(2))
      .connect(host: host, port: port) { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHTTPClientHandlers()
          return try NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>(
            wrappingChannelSynchronously: channel)
        }
      }

    var requestHeaders = HTTPHeaders(headers)
    requestHeaders.replaceOrAdd(name: "Host", value: "\(host):\(port)")
    requestHeaders.replaceOrAdd(name: "Connection", value: "close")
    requestHeaders.replaceOrAdd(name: "Content-Length", value: String(body?.readableBytes ?? 0))
    let head = HTTPRequestHead(
      version: .http1_1, method: HTTPMethod(rawValue: method), uri: path, headers: requestHeaders)

    // The exchange runs in its own task, feeding response parts to the caller.
    // Cancelling it (the caller stopped reading) closes the connection, which
    // the engine takes as "client gone" and stops generating.
    let (parts, partsContinuation) = AsyncThrowingStream<HTTPClientResponsePart, Error>.makeStream()
    let exchange = Task {
      do {
        try await channel.executeThenClose { inbound, outbound in
          try await outbound.write(.head(head))
          if let body, body.readableBytes > 0 { try await outbound.write(.body(.byteBuffer(body))) }
          try await outbound.write(.end(nil))
          for try await part in inbound {
            partsContinuation.yield(part)
            if case .end = part { break }
          }
        }
        partsContinuation.finish()
      } catch {
        partsContinuation.finish(throwing: error)
      }
    }
    partsContinuation.onTermination = { _ in exchange.cancel() }

    var iterator = parts.makeAsyncIterator()
    guard case .head(let responseHead) = try await iterator.next() else {
      exchange.cancel()
      throw ChannelError.inputClosed
    }

    let (bodyStream, bodyContinuation) = AsyncThrowingStream<ByteBuffer, Error>.makeStream()
    let pump = Task {
      do {
        while let part = try await iterator.next() {
          switch part {
          case .body(let buffer): bodyContinuation.yield(buffer)
          case .end: bodyContinuation.finish(); return
          case .head: continue
          }
        }
        bodyContinuation.finish()
      } catch {
        bodyContinuation.finish(throwing: error)
      }
    }
    bodyContinuation.onTermination = { _ in
      pump.cancel()
      exchange.cancel()
    }

    let responseHeaders = responseHead.headers.map { ($0.name, $0.value) }
    return (Head(status: Int(responseHead.status.code), headers: responseHeaders), bodyStream)
  }
}
