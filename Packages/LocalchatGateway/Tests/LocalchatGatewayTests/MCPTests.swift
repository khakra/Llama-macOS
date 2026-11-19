import AsyncHTTPClient
import Foundation
import MCP
import NIOCore
import XCTest

@testable import LocalchatGateway

struct EchoTool: GatewayTool {
  let name = "echo"
  let description = "Repeats the given text."
  let inputSchema: Value = .object([
    "type": .string("object"),
    "properties": .object(["text": .object(["type": .string("string")])]),
    "required": .array([.string("text")]),
  ])
  func call(arguments: [String: Value]) async throws -> String {
    guard let text = arguments["text"]?.stringValue else {
      throw NSError(domain: "echo", code: 1, userInfo: [NSLocalizedDescriptionKey: "text is required"])
    }
    return "echo: \(text)"
  }
}

final class MCPGatewayTests: XCTestCase {
  private var gateway: Gateway!
  private var port = 0

  override func setUp() async throws {
    port = freePort()
    gateway = Gateway(engine: { nil }, version: "test")
    try await gateway.start(.init(addresses: ["127.0.0.1"], port: port, hostPolicy: .init(loopbackOnly: true)))
    gateway.setTools([EchoTool()])
  }

  override func tearDown() async throws {
    await gateway.stop()
  }

  /// The SDK's own client, over Streamable HTTP, as Claude Desktop or the chat UI would connect.
  func testClientListsAndCallsTools() async throws {
    let client = Client(name: "test", version: "1.0")
    let transport = HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!, streaming: false)
    try await client.connect(transport: transport)

    let (tools, _) = try await client.listTools()
    XCTAssertEqual(tools.map(\.name), ["echo"])

    let (content, isError) = try await client.callTool(name: "echo", arguments: ["text": "hi"])
    XCTAssertEqual(isError, false)
    guard case .text(let text, _, _) = content.first else { return XCTFail("expected text, got \(content)") }
    XCTAssertEqual(text, "echo: hi")

    let (errorContent, failed) = try await client.callTool(name: "echo", arguments: [:])
    XCTAssertEqual(failed, true)
    guard case .text(let message, _, _) = errorContent.first else { return XCTFail("expected text") }
    XCTAssertTrue(message.contains("required"))

    let (_, unknown) = try await client.callTool(name: "nope", arguments: [:])
    XCTAssertEqual(unknown, true)
    await client.disconnect()
  }

  /// Every MCP client starts with `initialize`; a second client must not be refused
  /// ("Server is already initialized"), and clients must not block each other.
  func testSeveralClientsCanConnect() async throws {
    for round in 1...2 {
      let client = Client(name: "client-\(round)", version: "1.0")
      try await client.connect(
        transport: HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!, streaming: false))
      let (tools, _) = try await client.listTools()
      XCTAssertEqual(tools.map(\.name), ["echo"], "client \(round)")
      await client.disconnect()
    }

    let port = self.port
    try await withThrowingTaskGroup(of: Void.self) { group in
      for i in 0..<5 {
        group.addTask {
          let client = Client(name: "parallel-\(i)", version: "1.0")
          try await client.connect(
            transport: HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!, streaming: false))
          let (content, isError) = try await client.callTool(name: "echo", arguments: ["text": .string("\(i)")])
          XCTAssertEqual(isError, false)
          guard case .text(let text, _, _) = content.first else { return XCTFail("expected text") }
          XCTAssertEqual(text, "echo: \(i)")
          await client.disconnect()
        }
      }
      try await group.waitForAll()
    }
  }

  func testInfoAndForeignOrigin() async throws {
    let http = HTTPClient(eventLoopGroup: HTTPClient.defaultEventLoopGroup)
    defer { try? http.syncShutdown() }

    let info = try await http.execute(HTTPClientRequest(url: "http://127.0.0.1:\(port)/localchat/info"), timeout: .seconds(5))
    XCTAssertEqual(info.status.code, 200)
    let infoBody = String(buffer: try await info.body.collect(upTo: 100_000))
    XCTAssertTrue(infoBody.contains(#""path":"/mcp""#))
    XCTAssertTrue(infoBody.contains("echo"))

    var evil = HTTPClientRequest(url: "http://127.0.0.1:\(port)/mcp")
    evil.method = .POST
    evil.headers.add(name: "Origin", value: "https://evil.example")
    evil.headers.add(name: "Content-Type", value: "application/json")
    evil.headers.add(name: "Accept", value: "application/json, text/event-stream")
    evil.body = .bytes(ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
    let response = try await http.execute(evil, timeout: .seconds(5))
    XCTAssertEqual(response.status.code, 403)

    // A page opened as localhost may call 127.0.0.1 (a different origin to the browser).
    var preflight = HTTPClientRequest(url: "http://127.0.0.1:\(port)/mcp")
    preflight.method = .OPTIONS
    preflight.headers.add(name: "Origin", value: "http://localhost:\(port)")
    preflight.headers.add(name: "Access-Control-Request-Headers", value: "content-type, mcp-protocol-version")
    let allowed = try await http.execute(preflight, timeout: .seconds(5))
    XCTAssertEqual(allowed.status.code, 204)
    XCTAssertEqual(allowed.headers.first(name: "Access-Control-Allow-Origin"), "http://localhost:\(port)")
    XCTAssertEqual(allowed.headers.first(name: "Access-Control-Allow-Headers"), "content-type, mcp-protocol-version")

    var evilPreflight = HTTPClientRequest(url: "http://127.0.0.1:\(port)/mcp")
    evilPreflight.method = .OPTIONS
    evilPreflight.headers.add(name: "Origin", value: "https://evil.example")
    let refused = try await http.execute(evilPreflight, timeout: .seconds(5))
    XCTAssertEqual(refused.status.code, 403)
    XCTAssertNil(refused.headers.first(name: "Access-Control-Allow-Origin"))
  }
}
