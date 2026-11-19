import AsyncHTTPClient
import Darwin
import Foundation
import Hummingbird
import NIOCore
import XCTest

@testable import LocalchatGateway

final class HostPolicyTests: XCTestCase {
  func testLoopbackOnlyAcceptsLoopbackNames() {
    let policy = HostPolicy(loopbackOnly: true)
    for host in ["localhost:9931", "127.0.0.1:9931", "[::1]:9931", "LOCALHOST", "app.localhost:9931", "localhost."] {
      XCTAssertTrue(policy.allows(host: host), host)
    }
    XCTAssertTrue(policy.allows(host: nil))
  }

  func testLoopbackOnlyRejectsOtherNames() {
    let policy = HostPolicy(loopbackOnly: true)
    for host in ["evil.example", "evil.example:9931", "192.168.1.5:9931", "localhost.evil.example", "", "[::1"] {
      XCTAssertFalse(policy.allows(host: host), host)
    }
  }

  func testNetworkModeAcceptsAnything() {
    XCTAssertTrue(HostPolicy(loopbackOnly: false).allows(host: "my-mac.local:9931"))
  }
}

final class GatewayProxyTests: XCTestCase {
  private var client: HTTPClient!

  override func setUp() {
    client = HTTPClient(eventLoopGroup: HTTPClient.defaultEventLoopGroup)
  }

  override func tearDown() async throws {
    try await client.shutdown()
  }

  /// A stand-in engine: plain, streaming (SSE-like) and echo routes.
  private func startFakeEngine(port: Int) async throws -> Task<Void, Never> {
    let router = Router()
    router.get("/hello") { _, _ in "hi" }
    router.get("/stream") { _, _ -> Response in
      Response(
        status: .ok,
        headers: [.contentType: "text/event-stream"],
        body: ResponseBody { writer in
          for i in 0..<3 {
            try await writer.write(ByteBuffer(string: "data: \(i)\n\n"))
            try await Task.sleep(for: .milliseconds(200))
          }
          try await writer.finish(nil)
        })
    }
    router.get("/slow") { _, _ -> Response in
      Response(
        status: .ok,
        headers: [.contentType: "text/event-stream"],
        body: ResponseBody { writer in
          for i in 0..<100 {
            try await writer.write(ByteBuffer(string: "data: \(i)\n\n"))
            await slowChunksWritten.increment()
            try await Task.sleep(for: .milliseconds(50))
          }
          try await writer.finish(nil)
        })
    }
    router.get("/quiet") { _, _ -> Response in
      Response(
        status: .ok,
        headers: [.contentType: "text/event-stream"],
        body: ResponseBody { writer in
          try await Task.sleep(for: .seconds(2))
          try await writer.write(ByteBuffer(string: "data: late\n\n"))
          try await writer.finish(nil)
        })
    }
    router.post("/echo") { request, _ -> Response in
      let body = try await request.body.collect(upTo: 10_000_000)
      return Response(
        status: .created, headers: [.contentType: "application/octet-stream", .init("X-Engine")!: "yes"],
        body: ResponseBody(byteBuffer: body))
    }
    let signal = StartSignal()
    let task = Task {
      let app = Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: port)),
        onServerRunning: { _ in signal.succeed() })
      do {
        try await app.runService(gracefulShutdownSignals: [])
      } catch {
        signal.fail(error)
      }
    }
    try await signal.wait()
    return task
  }

  private func get(_ url: String, host: String? = nil) async throws -> (status: Int, headers: [String: String], body: String) {
    var request = HTTPClientRequest(url: url)
    if let host { request.headers.replaceOrAdd(name: "Host", value: host) }
    let response = try await client.execute(request, timeout: .seconds(10))
    let body = try await response.body.collect(upTo: 10_000_000)
    var headers: [String: String] = [:]
    for (name, value) in response.headers { headers[name.lowercased()] = value }
    return (Int(response.status.code), headers, String(buffer: body))
  }

  func testPassesThroughStatusHeadersAndBody() async throws {
    let enginePort = freePort(), gatewayPort = freePort()
    let engine = try await startFakeEngine(port: enginePort)
    let gateway = Gateway(engine: { EngineEndpoint(port: enginePort) })
    try await gateway.start(.init(addresses: ["127.0.0.1"], port: gatewayPort, hostPolicy: .init(loopbackOnly: true)))

    let hello = try await get("http://127.0.0.1:\(gatewayPort)/hello")
    XCTAssertEqual(hello.status, 200)
    XCTAssertEqual(hello.body, "hi")

    let missing = try await get("http://127.0.0.1:\(gatewayPort)/nope?x=1")
    XCTAssertEqual(missing.status, 404)

    var post = HTTPClientRequest(url: "http://127.0.0.1:\(gatewayPort)/echo")
    post.method = .POST
    let payload = String(repeating: "x", count: 1_000_000)
    post.body = .bytes(ByteBuffer(string: payload))
    let echoed = try await client.execute(post, timeout: .seconds(10))
    XCTAssertEqual(echoed.status.code, 201)
    XCTAssertEqual(echoed.headers.first(name: "X-Engine"), "yes")
    let echoedBody = try await echoed.body.collect(upTo: 10_000_000)
    XCTAssertEqual(echoedBody.readableBytes, payload.utf8.count)

    await gateway.stop()
    engine.cancel()
    await engine.value
  }

  func testStreamsChunksAsTheyArrive() async throws {
    let enginePort = freePort(), gatewayPort = freePort()
    let engine = try await startFakeEngine(port: enginePort)
    let gateway = Gateway(engine: { EngineEndpoint(port: enginePort) })
    try await gateway.start(.init(addresses: ["127.0.0.1"], port: gatewayPort, hostPolicy: .init(loopbackOnly: true)))

    let response = try await client.execute(
      HTTPClientRequest(url: "http://127.0.0.1:\(gatewayPort)/stream"), timeout: .seconds(10))
    XCTAssertEqual(response.headers.first(name: "content-type"), "text/event-stream")
    let start = Date()
    var arrivals: [TimeInterval] = []
    for try await _ in response.body {
      arrivals.append(Date().timeIntervalSince(start))
    }
    // Three writes 200 ms apart: the first must arrive well before the last,
    // which only happens if nothing buffers the whole body.
    XCTAssertGreaterThanOrEqual(arrivals.count, 2)
    XCTAssertLessThan(arrivals.first!, 0.3)
    XCTAssertGreaterThan(arrivals.last! - arrivals.first!, 0.25)

    await gateway.stop()
    engine.cancel()
    await engine.value
  }

  /// A quiet SSE feed (like `/models/sse`) must deliver its headers at once,
  /// not when the first event finally arrives.
  func testQuietStreamDeliversHeadersImmediately() async throws {
    let enginePort = freePort(), gatewayPort = freePort()
    let engine = try await startFakeEngine(port: enginePort)
    let gateway = Gateway(engine: { EngineEndpoint(port: enginePort) })
    try await gateway.start(.init(addresses: ["127.0.0.1"], port: gatewayPort, hostPolicy: .init(loopbackOnly: true)))

    let start = Date()
    let response = try await client.execute(
      HTTPClientRequest(url: "http://127.0.0.1:\(gatewayPort)/quiet"), timeout: .seconds(10))
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    XCTAssertEqual(response.headers.first(name: "content-type"), "text/event-stream")
    let body = try await response.body.collect(upTo: 1000)
    XCTAssertEqual(String(buffer: body), "data: late\n\n")

    await gateway.stop()
    engine.cancel()
    await engine.value
  }

  func testClientDisconnectCancelsUpstream() async throws {
    let enginePort = freePort(), gatewayPort = freePort()
    let engine = try await startFakeEngine(port: enginePort)
    let gateway = Gateway(engine: { EngineEndpoint(port: enginePort) })
    try await gateway.start(.init(addresses: ["127.0.0.1"], port: gatewayPort, hostPolicy: .init(loopbackOnly: true)))
    await slowChunksWritten.reset()

    // Read a couple of chunks, then hang up.
    let reader = Task {
      let response = try await client.execute(
        HTTPClientRequest(url: "http://127.0.0.1:\(gatewayPort)/slow"), timeout: .seconds(10))
      var seen = 0
      for try await _ in response.body {
        seen += 1
        if seen == 2 { break }
      }
    }
    _ = try await reader.value
    try await Task.sleep(for: .seconds(1.5))
    let written = await slowChunksWritten.value
    // Uncancelled, the engine would have written ~30 chunks by now (of 100).
    XCTAssertLessThan(written, 15, "engine kept streaming after the client left")

    await gateway.stop()
    engine.cancel()
    await engine.value
  }

  func testEngineDownGives503() async throws {
    let gatewayPort = freePort(), deadPort = freePort()
    let gateway = Gateway(engine: { EngineEndpoint(port: deadPort) })
    try await gateway.start(.init(addresses: ["127.0.0.1"], port: gatewayPort, hostPolicy: .init(loopbackOnly: true)))
    let response = try await get("http://127.0.0.1:\(gatewayPort)/v1/models")
    XCTAssertEqual(response.status, 503)
    XCTAssertTrue(response.body.contains("unavailable_error"))
    await gateway.stop()
  }

  func testForeignHostIsRejected() async throws {
    let enginePort = freePort(), gatewayPort = freePort()
    let engine = try await startFakeEngine(port: enginePort)
    let gateway = Gateway(engine: { EngineEndpoint(port: enginePort) })
    try await gateway.start(.init(addresses: ["127.0.0.1"], port: gatewayPort, hostPolicy: .init(loopbackOnly: true)))
    let response = try await get("http://127.0.0.1:\(gatewayPort)/hello", host: "evil.example")
    XCTAssertEqual(response.status, 403)
    await gateway.stop()
    engine.cancel()
    await engine.value
  }

  func testRestartOnSamePortAndBindFailure() async throws {
    let gatewayPort = freePort()
    let gateway = Gateway(engine: { nil })
    let config = GatewayConfiguration(addresses: ["127.0.0.1"], port: gatewayPort, hostPolicy: .init(loopbackOnly: true))
    try await gateway.start(config)
    try await gateway.start(config)  // replaces itself without "address in use"
    let isRunning = await gateway.isRunning
    XCTAssertTrue(isRunning)

    // A second gateway can't take the same port, and leaves nothing running.
    let other = Gateway(engine: { nil })
    do {
      try await other.start(config)
      XCTFail("expected bind failure")
    } catch {}
    let otherRunning = await other.isRunning
    XCTAssertFalse(otherRunning)

    await gateway.stop()
    try await other.start(config)  // port released by stop()
    await other.stop()
  }
}

actor Counter {
  private(set) var value = 0
  func increment() { value += 1 }
  func reset() { value = 0 }
}
let slowChunksWritten = Counter()

/// A port nothing is listening on right now.
func freePort() -> Int {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  defer { close(fd) }
  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  addr.sin_port = 0
  var len = socklen_t(MemoryLayout<sockaddr_in>.size)
  withUnsafeMutablePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      _ = bind(fd, $0, len)
      _ = getsockname(fd, $0, &len)
    }
  }
  return Int(UInt16(bigEndian: addr.sin_port))
}
