// FORK: localchat gateway (docs/gateway.md, phase 3).
import Foundation
import HTTPTypes
import Hummingbird
import MCP
import NIOCore

/// A tool the app offers over the gateway's MCP endpoint (`/mcp`).
/// The app implements these (native tools need Swift); the gateway only serves them.
public protocol GatewayTool: Sendable {
  var name: String { get }
  var description: String { get }
  /// JSON Schema for the arguments, as an MCP `Value` (an `.object` with `properties`).
  var inputSchema: Value { get }
  /// Runs the tool. Return text for the model; throw to report an error to it.
  func call(arguments: [String: Value]) async throws -> String
}

/// The tools currently offered. Set by the app; read on every list or call.
final class GatewayTools: @unchecked Sendable {
  private let lock = NSLock()
  private var tools: [String: GatewayTool] = [:]
  private var order: [String] = []

  var all: [GatewayTool] { lock.withLock { order.compactMap { tools[$0] } } }
  func tool(_ name: String) -> GatewayTool? { lock.withLock { tools[name] } }
  func replace(_ newTools: [GatewayTool]) {
    lock.withLock {
      tools = Dictionary(newTools.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
      order = newTools.map(\.name)
    }
  }
}

/// The MCP server behind `/mcp`: Streamable HTTP without sessions.
///
/// Each HTTP request gets a fresh `Server` and `StatelessHTTPServerTransport`.
/// The SDK's `Server` keeps per-client state and refuses a second `initialize`,
/// so one shared instance would only ever serve the first client. It isn't
/// strict by default, so `tools/list` and `tools/call` work without a prior
/// `initialize` on the same instance, which is what stateless mode needs.
struct GatewayMCP: Sendable {
  private let tools: GatewayTools
  private let version: String

  init(tools: GatewayTools, version: String) {
    self.tools = tools
    self.version = version
  }

  private func makeServer() async -> Server {
    let server = Server(
      name: "LocalChat", version: version,
      capabilities: .init(tools: .init(listChanged: false)))
    let tools = self.tools
    await server.withMethodHandler(ListTools.self) { _ in
      .init(tools: tools.all.map { Tool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema) })
    }
    await server.withMethodHandler(CallTool.self) { params in
      guard let tool = tools.tool(params.name) else {
        return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
      }
      do {
        let text = try await tool.call(arguments: params.arguments ?? [:])
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
      } catch {
        return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
      }
    }
    return server
  }

  func handle(_ request: Request) async -> Response {
    let server = await makeServer()
    let transport = StatelessHTTPServerTransport()
    do {
      try await server.start(transport: transport)
    } catch {
      return .jsonError(.internalServerError, type: "mcp_error", message: "The MCP server didn't start.")
    }
    defer { Task { await server.stop() } }

    var headers: [String: String] = [:]
    for field in request.headers {
      let name = field.name.rawName
      headers[name] = headers[name].map { "\($0), \(field.value)" } ?? field.value
    }
    // HTTP/1 Host arrives as the request's authority, not as a header.
    if let authority = request.head.authority { headers["Host"] = authority }
    let body = try? await request.body.collect(upTo: 10_000_000)

    let response = await transport.handleRequest(
      MCP.HTTPRequest(
        method: request.method.rawValue, headers: headers,
        body: body.map { Data($0.readableBytesView) }, path: request.uri.path))

    var fields = HTTPFields()
    for (name, value) in response.headers {
      if let fieldName = HTTPField.Name(name) { fields.append(HTTPField(name: fieldName, value: value)) }
    }
    let status = HTTPTypes.HTTPResponse.Status(code: response.statusCode)

    if case .stream(let stream, _) = response {
      return Response(
        status: status, headers: fields,
        body: ResponseBody { writer in
          for try await chunk in stream { try await writer.write(ByteBuffer(bytes: chunk)) }
          try await writer.finish(nil)
        })
    }
    let data = response.bodyData ?? Data()
    return Response(status: status, headers: fields, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
  }
}
