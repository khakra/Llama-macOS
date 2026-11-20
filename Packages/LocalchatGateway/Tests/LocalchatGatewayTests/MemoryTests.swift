import AsyncHTTPClient
import Foundation
import Hummingbird
import MCP
import NIOCore
import XCTest

@testable import LocalchatGateway

private func tempStoreURL() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("memory-\(UUID().uuidString)/memory.json")
}

final class MemoryStoreTests: XCTestCase {
  func testAddMergesNearDuplicatesAndPersists() async throws {
    let url = tempStoreURL()
    let store = JSONMemoryStore(url: url)
    let (first, isNew) = try await store.add("Is vegetarian", source: .learned)
    XCTAssertTrue(isNew)
    let (again, againNew) = try await store.add("  is   vegetarian.\n", source: .learned)
    XCTAssertFalse(againNew)
    XCTAssertEqual(again.id, first.id)
    _ = try await store.add("Prefers concise answers with code examples", source: .user)
    let count = await store.all().count
    XCTAssertEqual(count, 2)

    // A user statement takes over a learned near-duplicate; a learned one never overrides the user's.
    let (byUser, _) = try await store.add("Is a vegetarian", source: .user)
    XCTAssertEqual(byUser.id, first.id)
    XCTAssertEqual(byUser.source, .user)
    let (learnedAgain, _) = try await store.add("Is vegetarian", source: .learned)
    XCTAssertEqual(learnedAgain.text, "Is a vegetarian")

    let reloaded = JSONMemoryStore(url: url)
    let texts = await reloaded.all().map(\.text).sorted()
    XCTAssertEqual(texts, ["Is a vegetarian", "Prefers concise answers with code examples"])
    let raw = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(raw.contains(#""version" : 1"#))
  }

  func testUpdateDeleteAndValidation() async throws {
    let store = JSONMemoryStore(url: tempStoreURL())
    let (memory, _) = try await store.add("Lives in Seattle", source: .learned)
    let updated = try await store.update(id: memory.id, text: "Lives in Portland", source: .user)
    XCTAssertEqual(updated?.text, "Lives in Portland")
    XCTAssertEqual(updated?.source, .user)
    let missing = try await store.update(id: "nope", text: "x", source: .user)
    XCTAssertNil(missing)
    do {
      _ = try await store.add("   ", source: .user)
      XCTFail("empty accepted")
    } catch {}
    do {
      _ = try await store.add(String(repeating: "x", count: 301), source: .user)
      XCTFail("too long accepted")
    } catch {}
    let deleted = try await store.delete(id: memory.id)
    XCTAssertTrue(deleted)
    try await store.deleteAll()
    let isEmpty = await store.all().isEmpty
    XCTAssertTrue(isEmpty)
  }
}

final class MemoryInjectorTests: XCTestCase {
  private func memory(_ text: String, _ source: Memory.Source, secondsAgo: Double) -> Memory {
    let date = Date().addingTimeInterval(-secondsAgo)
    return Memory(id: UUID().uuidString, text: text, source: source, createdAt: date, updatedAt: date)
  }

  func testOrderAndBudget() throws {
    let block = try XCTUnwrap(
      MemoryInjector.block(for: [
        memory("Learned old", .learned, secondsAgo: 100), memory("Learned new", .learned, secondsAgo: 1),
        memory("User fact", .user, secondsAgo: 500),
      ]))
    let lines = block.split(separator: "\n").filter { $0.hasPrefix("- ") }
    XCTAssertEqual(lines, ["- User fact", "- Learned new", "- Learned old"])
    XCTAssertNil(MemoryInjector.block(for: []))

    let many = (0..<200).map { memory("Fact number \($0) with some padding words", .learned, secondsAgo: Double($0)) }
    let capped = try XCTUnwrap(MemoryInjector.block(for: many))
    XCTAssertLessThanOrEqual(capped.count, MemoryInjector.budget)
    XCTAssertTrue(capped.contains("Fact number 0 "))  // newest kept
  }

  func testInjectIntoEachSystemMessageShape() {
    let block = "## About the user\n- X"
    let none = MemoryInjector.inject(block, into: ["messages": [["role": "user", "content": "hi"]]])
    let noneMessages = none["messages"] as? [[String: Any]]
    XCTAssertEqual(noneMessages?.first?["role"] as? String, "system")
    XCTAssertEqual(noneMessages?.count, 2)

    let text = MemoryInjector.inject(block, into: ["messages": [["role": "system", "content": "Be brief."], ["role": "user", "content": "hi"]]])
    XCTAssertEqual((text["messages"] as? [[String: Any]])?.first?["content"] as? String, "Be brief.\n\n" + block)

    let parts = MemoryInjector.inject(
      block, into: ["messages": [["role": "system", "content": [["type": "text", "text": "Be brief."]]]]])
    let partList = (parts["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
    XCTAssertEqual(partList?.count, 2)

    let untouched = MemoryInjector.inject(nil, into: ["messages": [["role": "user", "content": "hi"]]])
    XCTAssertEqual((untouched["messages"] as? [[String: Any]])?.count, 1)
  }
}

/// The gateway with a fake engine and a fake cloud provider that both record what they receive.
final class MemoryGatewayTests: XCTestCase {
  private var gateway: Gateway!
  private var client: HTTPClient!
  private var tasks: [Task<Void, Never>] = []
  private var port = 0
  private var store: JSONMemoryStore!
  private let persisted = Recorder()
  static let seen = SeenBodies()

  override func setUp() async throws {
    client = HTTPClient(eventLoopGroup: HTTPClient.defaultEventLoopGroup)
    let enginePort = freePort(), providerPort = freePort()
    port = freePort()
    await Self.seen.reset()

    for (routerPort, label) in [(enginePort, "engine"), (providerPort, "cloud")] {
      let router = Router()
      let chatPath = label == "engine" ? "/v1/chat/completions" : "/v1/chat/completions"
      router.post(.init(stringLiteral: chatPath)) { request, _ -> Response in
        let body = try await request.body.collect(upTo: 1_000_000)
        await MemoryGatewayTests.seen.add(label, String(buffer: body))
        return .json(["model": "x", "choices": [["message": ["role": "assistant", "content": "ok"]]]])
      }
      router.get("/v1/models") { _, _ -> Response in .json(["data": [] as [Any]]) }
      let signal = StartSignal()
      tasks.append(Task {
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: routerPort)),
                              onServerRunning: { _ in signal.succeed() })
        do { try await app.runService(gracefulShutdownSignals: []) } catch { signal.fail(error) }
      })
      try await signal.wait()
    }

    gateway = Gateway(engine: { EngineEndpoint(port: enginePort) })
    try await gateway.start(.init(addresses: ["127.0.0.1"], port: port, hostPolicy: .init(loopbackOnly: true)))
    gateway.setCloudProviders([
      CloudProvider(preset: .openRouter, apiKey: "k", models: ["v/m"], baseURL: URL(string: "http://127.0.0.1:\(providerPort)/v1")!)
    ])
    store = JSONMemoryStore(url: tempStoreURL())
    _ = try await store.add("Is vegetarian", source: .user)
    let persisted = self.persisted
    gateway.configureMemory(store: store, settings: MemorySettings(enabled: true, withCloud: false)) { settings in
      Task { await persisted.set(Data("\(settings.enabled),\(settings.withCloud)".utf8), auth: nil) }
    }
  }

  override func tearDown() async throws {
    await gateway.stop()
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
    try await client.shutdown()
  }

  private func send(_ method: String, _ path: String, json: [String: Any]? = nil, conversation: String? = nil, origin: String? = nil)
    async throws -> (status: Int, body: String)
  {
    var request = HTTPClientRequest(url: "http://127.0.0.1:\(port)\(path)")
    request.method = .init(rawValue: method)
    if let conversation { request.headers.add(name: "X-Conversation-Id", value: conversation) }
    if let origin { request.headers.add(name: "Origin", value: origin) }
    if let json {
      request.headers.add(name: "Content-Type", value: "application/json")
      request.body = .bytes(ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: json)))
    }
    let response = try await client.execute(request, timeout: .seconds(10))
    return (Int(response.status.code), String(buffer: try await response.body.collect(upTo: 1_000_000)))
  }

  private func chat(_ model: String, conversation: String?) async throws {
    _ = try await send("POST", "/v1/chat/completions",
                       json: ["model": model, "messages": [["role": "user", "content": "dinner idea?"]]],
                       conversation: conversation)
  }

  func testInjectsOnlyIntoLocalChatConversations() async throws {
    try await chat("local/model:Q4", conversation: "c1::local/model:Q4")
    try await chat("local/model:Q4", conversation: nil)  // title generation, other apps
    let engine = await Self.seen.bodies("engine")
    XCTAssertEqual(engine.count, 2)
    XCTAssertTrue(engine[0].contains("About the user") && engine[0].contains("Is vegetarian"))
    XCTAssertFalse(engine[1].contains("About the user"))
  }

  func testCloudFollowsTheSwitchAndMasterSwitchWorks() async throws {
    try await chat("cloud@openrouter/v/m", conversation: "c2")
    var cloud = await Self.seen.bodies("cloud")
    XCTAssertFalse(cloud.last?.contains("About the user") ?? true, "withCloud is off")

    let patched = try await send("PATCH", "/localchat/memory/settings", json: ["withCloud": true])
    XCTAssertEqual(patched.status, 200)
    try await chat("cloud@openrouter/v/m", conversation: "c2")
    cloud = await Self.seen.bodies("cloud")
    XCTAssertTrue(cloud.last?.contains("Is vegetarian") ?? false)
    try await Task.sleep(for: .milliseconds(100))
    let saved = await persisted.value.0
    XCTAssertEqual(String(data: saved, encoding: .utf8), "true,true")

    _ = try await send("PATCH", "/localchat/memory/settings", json: ["enabled": false])
    try await chat("local/model:Q4", conversation: "c3")
    let engine = await Self.seen.bodies("engine")
    XCTAssertFalse(engine.last?.contains("About the user") ?? true)
  }

  func testSettingsAPI() async throws {
    let added = try await send("POST", "/localchat/memory", json: ["text": "Lives in Portland"])
    XCTAssertEqual(added.status, 201)
    let duplicate = try await send("POST", "/localchat/memory", json: ["text": "lives in portland"])
    XCTAssertEqual(duplicate.status, 200)

    let list = try await send("GET", "/localchat/memory")
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(list.body.utf8)) as? [String: Any])
    let memories = try XCTUnwrap(json["memories"] as? [[String: Any]])
    XCTAssertEqual(memories.count, 2)
    // The duplicate kept one memory, with the newer wording.
    let id = try XCTUnwrap(memories.first { ($0["text"] as? String)?.lowercased() == "lives in portland" }?["id"] as? String)

    let edited = try await send("PATCH", "/localchat/memory/\(id)", json: ["text": "Lives in Portland, Oregon"])
    XCTAssertEqual(edited.status, 200)
    XCTAssertTrue(edited.body.contains(#""source":"user""#))
    let tooLong = try await send("POST", "/localchat/memory", json: ["text": String(repeating: "x", count: 400)])
    XCTAssertEqual(tooLong.status, 400)
    let removed = try await send("DELETE", "/localchat/memory/\(id)")
    XCTAssertEqual(removed.status, 200)
    let evil = try await send("POST", "/localchat/memory", json: ["text": "planted"], origin: "https://evil.example")
    XCTAssertEqual(evil.status, 403)
    let cleared = try await send("DELETE", "/localchat/memory")
    XCTAssertEqual(cleared.status, 200)
    let empty = await store.all().isEmpty
    XCTAssertTrue(empty)
  }

  func testTools() async throws {
    gateway.setTools([RememberTool(store: store), ForgetTool(store: store), RecallMemoriesTool(store: store)])
    let mcp = Client(name: "test", version: "1")
    try await mcp.connect(transport: HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!, streaming: false))
    func text(_ name: String, _ args: [String: Value]) async throws -> String {
      let (content, _) = try await mcp.callTool(name: name, arguments: args)
      guard case .text(let text, _, _) = content.first else { return "" }
      return text
    }
    let remembered = try await text("remember", ["text": "Prefers metric units"])
    XCTAssertTrue(remembered.hasPrefix("Remembered"))
    _ = try await text("remember", ["text": "Prefers dark roast coffee"])
    _ = try await text("remember", ["text": "Prefers light roast tea"])
    let recalled = try await text("recall_memories", [:])
    XCTAssertTrue(recalled.contains("Prefers metric units") && recalled.contains("Is vegetarian"))
    let forgotten = try await text("forget", ["memory": "metric"])
    XCTAssertEqual(forgotten, "Forgot: Prefers metric units")
    let ambiguous = try await text("forget", ["memory": "Prefers roast"])
    XCTAssertTrue(ambiguous.hasPrefix("Several memories match"))
    let none = try await text("forget", ["memory": "astronaut"])
    XCTAssertTrue(none.hasPrefix("No saved memory"))
    await mcp.disconnect()
  }
}

actor SeenBodies {
  private var store: [String: [String]] = [:]
  func reset() { store = [:] }
  func add(_ label: String, _ body: String) { store[label, default: []].append(body) }
  func bodies(_ label: String) -> [String] { store[label] ?? [] }
}
