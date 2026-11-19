import AsyncHTTPClient
import Foundation
import Hummingbird
import NIOCore
import XCTest

@testable import LocalchatGateway

final class CloudModelIDTests: XCTestCase {
  func testRoundTrip() {
    let id = CloudModelID.make(provider: "openrouter", model: "anthropic/claude-sonnet-4.5")
    XCTAssertEqual(id, "cloud@openrouter/anthropic/claude-sonnet-4.5")
    let parsed = CloudModelID.parse(id)
    XCTAssertEqual(parsed?.provider, "openrouter")
    XCTAssertEqual(parsed?.model, "anthropic/claude-sonnet-4.5")
  }

  func testLocalIDsAreNotCloud() {
    for id in ["ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M", "openai/gpt-oss-20b", "cloud/x", "cloud@", "cloud@openai"] {
      XCTAssertNil(CloudModelID.parse(id), id)
    }
  }
}

final class RequestSanitizerTests: XCTestCase {
  let uiRequest: [String: Any] = [
    "model": "cloud@openrouter/x/y", "stream": true, "max_tokens": -1, "temperature": 0.8,
    "top_k": 40, "min_p": 0.05, "dry_multiplier": 0, "samplers": ["top_k"], "return_progress": true,
    "sse_ping_interval": 1, "timings_per_token": false, "reasoning_format": "auto",
    "chat_template_kwargs": ["enable_thinking": true], "reasoning_effort": "high", "tools": [] as [Any],
    "messages": [
      ["role": "user", "content": "hi"],
      ["role": "assistant", "content": "ok", "reasoning_content": "thought", "tool_calls": [] as [Any]],
    ],
  ]

  func testOpenRouterKeepsOnlyAllowedFields() {
    let provider = CloudProvider(preset: .openRouter, apiKey: "k", models: ["x/y"])
    let info = CloudModelInfo(id: "x/y", reasoning: true)
    let out = RequestSanitizer.sanitize(uiRequest, provider: provider, model: "x/y", info: info)
    XCTAssertEqual(out["model"] as? String, "x/y")
    XCTAssertEqual(out["temperature"] as? Double, 0.8)
    XCTAssertEqual(out["top_k"] as? Int, 40)  // OpenRouter accepts it
    XCTAssertEqual((out["reasoning"] as? [String: String])?["effort"], "high")
    for dropped in ["max_tokens", "dry_multiplier", "samplers", "return_progress", "sse_ping_interval",
                    "timings_per_token", "reasoning_format", "chat_template_kwargs", "reasoning_effort", "tools"] {
      XCTAssertNil(out[dropped], dropped)
    }
    let messages = out["messages"] as? [[String: Any]]
    XCTAssertNil(messages?[1]["reasoning_content"])
    XCTAssertNotNil(messages?[1]["tool_calls"])
  }

  func testOpenAIRenamesMaxTokensAndDropsSamplingForReasoningModels() {
    var request = uiRequest
    request["max_tokens"] = 500
    let provider = CloudProvider(preset: .openAI, apiKey: "k", models: ["gpt-5"])
    let out = RequestSanitizer.sanitize(
      request, provider: provider, model: "gpt-5", info: CloudModelInfo.guess(provider: "openai", model: "gpt-5"))
    XCTAssertEqual(out["max_completion_tokens"] as? Int, 500)
    XCTAssertNil(out["max_tokens"])
    XCTAssertNil(out["temperature"])
    XCTAssertNil(out["top_k"])
    XCTAssertEqual(out["reasoning_effort"] as? String, "high")
  }
}

final class StreamRewriterTests: XCTestCase {
  func testRenamesReasoningRewritesModelDropsComments() throws {
    var rewriter = StreamRewriter(modelID: "cloud@openrouter/x/y")
    XCTAssertNil(rewriter.rewrite(line: ": OPENROUTER PROCESSING"))
    XCTAssertNil(rewriter.rewrite(line: ""))
    let out = try XCTUnwrap(rewriter.rewrite(
      line: #"data: {"model":"x/y","choices":[{"index":0,"delta":{"reasoning":"hmm","reasoning_details":[{}]}}]}"#))
    XCTAssertTrue(out.hasPrefix("data: ") && out.hasSuffix("\n\n"))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.dropFirst(6).utf8)) as? [String: Any])
    XCTAssertEqual(json["model"] as? String, "cloud@openrouter/x/y")
    let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
    XCTAssertEqual(delta?["reasoning_content"] as? String, "hmm")
    XCTAssertNil(delta?["reasoning"])
    XCTAssertNil(delta?["reasoning_details"])
    XCTAssertFalse(rewriter.sawDone)
    XCTAssertEqual(rewriter.rewrite(line: "data: [DONE]"), "data: [DONE]\n\n")
    XCTAssertTrue(rewriter.sawDone)
  }
}

final class CloudSynthesisTests: XCTestCase {
  func testMergeKeepsDataAndModelsAligned() {
    let provider = CloudProvider(preset: .openRouter, apiKey: "k", models: ["x/y"])
    let entry = CloudSynthesis.modelEntries(id: "cloud@openrouter/x/y", provider: provider, info: CloudModelInfo(id: "x/y"))
    let engine: [String: Any] = ["object": "list", "data": [["id": "a"], ["id": "b"]], "models": [["name": "a"], ["name": "b"]]]
    let merged = CloudSynthesis.mergeModelList(engine: engine, cloud: [entry])
    XCTAssertEqual((merged["data"] as? [Any])?.count, 3)
    XCTAssertEqual((merged["models"] as? [Any])?.count, 3)

    let noDetails = CloudSynthesis.mergeModelList(engine: ["data": [["id": "a"]]], cloud: [entry])
    XCTAssertEqual((noDetails["data"] as? [Any])?.count, 2)
    XCTAssertNil(noDetails["models"])

    let engineDown = CloudSynthesis.mergeModelList(engine: nil, cloud: [entry])
    XCTAssertEqual((engineDown["data"] as? [Any])?.count, 1)
    XCTAssertEqual((engineDown["models"] as? [Any])?.count, 1)
  }

  func testPropsShowThinkingControlsOnlyForReasoningModels() {
    let reasoning = CloudSynthesis.props(info: CloudModelInfo(id: "r", contextLength: 200_000, inputModalities: ["text", "image"], reasoning: true))
    XCTAssertTrue((reasoning["chat_template"] as? String)?.contains("enable_thinking") == true)
    XCTAssertEqual(((reasoning["default_generation_settings"] as? [String: Any])?["n_ctx"]) as? Int, 200_000)
    XCTAssertEqual((reasoning["modalities"] as? [String: Bool])?["vision"], true)
    let plain = CloudSynthesis.props(info: CloudModelInfo(id: "p"))
    XCTAssertEqual(plain["chat_template"] as? String, "")
  }
}

final class CloudAccessPolicyTests: XCTestCase {
  func testOnlyLocalClientsFromOurOrigin() {
    let policy = CloudAccessPolicy(port: 9931)
    XCTAssertTrue(policy.allows(origin: nil, clientIsLoopback: true))
    XCTAssertTrue(policy.allows(origin: "http://localhost:9931", clientIsLoopback: true))
    XCTAssertTrue(policy.allows(origin: "http://127.0.0.1:9931", clientIsLoopback: true))
    XCTAssertTrue(policy.allows(origin: "http://[::1]:9931", clientIsLoopback: true))
    XCTAssertFalse(policy.allows(origin: "https://evil.example", clientIsLoopback: true))
    XCTAssertFalse(policy.allows(origin: "http://localhost:3000", clientIsLoopback: true))
    XCTAssertFalse(policy.allows(origin: "null", clientIsLoopback: true))
    XCTAssertFalse(policy.allows(origin: nil, clientIsLoopback: false))
  }
}

/// The gateway in front of a fake engine and a fake OpenAI-compatible provider.
final class CloudGatewayTests: XCTestCase {
  private var client: HTTPClient!
  private var tasks: [Task<Void, Never>] = []
  private var gateway: Gateway!
  private var gatewayPort = 0
  static let received = Recorder()

  override func setUp() async throws {
    client = HTTPClient(eventLoopGroup: HTTPClient.defaultEventLoopGroup)
    let enginePort = freePort(), providerPort = freePort()
    gatewayPort = freePort()

    let engine = Router()
    engine.get("/v1/models") { _, _ -> Response in
      .json(["object": "list", "data": [["id": "local/model:Q4", "status": ["value": "loaded"]]]])
    }
    engine.post("/v1/chat/completions") { _, _ in "local answer" }
    tasks.append(try await serve(engine, port: enginePort))

    let provider = Router()
    provider.get("/v1/models") { _, _ -> Response in
      .json(["data": [["id": "vendor/smart", "name": "Vendor: Smart", "context_length": 64000,
                       "architecture": ["input_modalities": ["text", "image"]], "supported_parameters": ["reasoning"]]]])
    }
    provider.post("/v1/chat/completions") { request, _ -> Response in
      let body = try await request.body.collect(upTo: 1_000_000)
      await CloudGatewayTests.received.set(Data(body.readableBytesView), auth: request.headers[.authorization])
      if request.headers[.authorization] != "Bearer good-key" {
        return .json(["error": ["message": "No auth credentials found"]], status: .unauthorized)
      }
      return Response(
        status: .ok, headers: [.contentType: "text/event-stream"],
        body: ResponseBody { writer in
          try await writer.write(ByteBuffer(string: ": OPENROUTER PROCESSING\n\n"))
          try await writer.write(ByteBuffer(string: #"data: {"model":"vendor/smart","choices":[{"index":0,"delta":{"reasoning":"thinking"}}]}"# + "\n\n"))
          try await writer.write(ByteBuffer(string: #"data: {"model":"vendor/smart","choices":[{"index":0,"delta":{"content":"Hello"}}]}"# + "\n\n"))
          try await writer.write(ByteBuffer(string: "data: [DONE]\n\n"))
          try await writer.finish(nil)
        })
    }
    tasks.append(try await serve(provider, port: providerPort))

    gateway = Gateway(engine: { EngineEndpoint(port: enginePort) })
    try await gateway.start(.init(addresses: ["127.0.0.1"], port: gatewayPort, hostPolicy: .init(loopbackOnly: true)))
    gateway.setCloudProviders([
      CloudProvider(preset: .openRouter, apiKey: "good-key", models: ["vendor/smart"],
                    baseURL: URL(string: "http://127.0.0.1:\(providerPort)/v1")!)
    ])
  }

  override func tearDown() async throws {
    await gateway.stop()
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
    try await client.shutdown()
  }

  private func serve(_ router: Router<BasicRequestContext>, port: Int) async throws -> Task<Void, Never> {
    let signal = StartSignal()
    let task = Task {
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: port)),
                            onServerRunning: { _ in signal.succeed() })
      do { try await app.runService(gracefulShutdownSignals: []) } catch { signal.fail(error) }
    }
    try await signal.wait()
    return task
  }

  private func request(_ method: String, _ path: String, json: [String: Any]? = nil, origin: String? = nil)
    async throws -> (status: Int, body: String)
  {
    var request = HTTPClientRequest(url: "http://127.0.0.1:\(gatewayPort)\(path)")
    request.method = .init(rawValue: method)
    if let origin { request.headers.add(name: "Origin", value: origin) }
    if let json {
      request.headers.add(name: "Content-Type", value: "application/json")
      request.body = .bytes(ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: json)))
    }
    let response = try await client.execute(request, timeout: .seconds(10))
    let body = try await response.body.collect(upTo: 10_000_000)
    return (Int(response.status.code), String(buffer: body))
  }

  func testModelListMergesCloudModels() async throws {
    let (status, body) = try await request("GET", "/v1/models")
    XCTAssertEqual(status, 200)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    let ids = (json["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
    XCTAssertEqual(ids, ["local/model:Q4", "cloud@openrouter/vendor/smart"])
    let cloud = (json["data"] as? [[String: Any]])?.last
    XCTAssertEqual(cloud?["context_length"] as? Int, 64000)
    XCTAssertEqual((cloud?["architecture"] as? [String: Any])?["input_modalities"] as? [String], ["text", "image"])
  }

  func testForeignOriginSeesNoCloudModelsAndCannotChat() async throws {
    let (_, list) = try await request("GET", "/v1/models", origin: "https://evil.example")
    XCTAssertFalse(list.contains("cloud@"))
    let (status, _) = try await request(
      "POST", "/v1/chat/completions", json: ["model": "cloud@openrouter/vendor/smart", "messages": []],
      origin: "https://evil.example")
    XCTAssertEqual(status, 403)
  }

  func testPropsAndLoadForCloudModel() async throws {
    let (status, body) = try await request("GET", "/props?model=cloud@openrouter/vendor/smart")
    XCTAssertEqual(status, 200)
    XCTAssertTrue(body.contains("enable_thinking"))
    XCTAssertTrue(body.contains("64000"))
    let load = try await request("POST", "/models/load", json: ["model": "cloud@openrouter/vendor/smart"])
    XCTAssertEqual(load.status, 200)
    let unknown = try await request("POST", "/models/load", json: ["model": "cloud@openrouter/not/chosen"])
    XCTAssertEqual(unknown.status, 404)
  }

  func testStreamingChatIsCleanedAndRewritten() async throws {
    let (status, body) = try await request(
      "POST", "/v1/chat/completions",
      json: ["model": "cloud@openrouter/vendor/smart", "stream": true, "samplers": ["x"], "max_tokens": -1,
             "messages": [["role": "user", "content": "hi"]]],
      origin: "http://localhost:\(gatewayPort)")
    XCTAssertEqual(status, 200)
    XCTAssertFalse(body.contains("OPENROUTER PROCESSING"))
    XCTAssertTrue(body.contains(#""reasoning_content":"thinking""#))
    XCTAssertTrue(body.contains("cloud@openrouter/vendor/smart"))
    XCTAssertTrue(body.hasSuffix("data: [DONE]\n\n"))

    let (sent, auth) = await Self.received.value
    XCTAssertEqual(auth, "Bearer good-key")
    let upstream = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
    XCTAssertEqual(upstream["model"] as? String, "vendor/smart")
    XCTAssertNil(upstream["samplers"])
    XCTAssertNil(upstream["max_tokens"])
  }

  func testBadKeyGivesClearError() async throws {
    gateway.setCloudProviders([
      CloudProvider(preset: .openRouter, apiKey: "bad-key", models: ["vendor/smart"],
                    baseURL: URL(string: "http://127.0.0.1:\(freePort())/v1")!)
    ])
    // Unreachable provider -> 502 with a message.
    let unreachable = try await request(
      "POST", "/v1/chat/completions", json: ["model": "cloud@openrouter/vendor/smart", "messages": []])
    XCTAssertEqual(unreachable.status, 502)
    XCTAssertTrue(unreachable.body.contains("Couldn't reach OpenRouter"))
  }

  func testLocalModelsStillPassThrough() async throws {
    let (status, body) = try await request("POST", "/v1/chat/completions", json: ["model": "local/model:Q4", "messages": []])
    XCTAssertEqual(status, 200)
    XCTAssertEqual(body, "local answer")
  }
}

actor Recorder {
  private(set) var value: (Data, String?) = (Data(), nil)
  func set(_ data: Data, auth: String?) { value = (data, auth) }
}
