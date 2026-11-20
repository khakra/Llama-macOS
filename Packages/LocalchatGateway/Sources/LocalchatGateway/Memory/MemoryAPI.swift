// FORK: localchat memory (docs/memory.md).
import Foundation
import Hummingbird
import MCP
import NIOCore

/// `/localchat/memory`: what the chat UI's Settings › Memory reads and changes.
/// Same access rule as the other `/localchat` endpoints.
struct MemoryAPI: Sendable {
  static let prefix = "/localchat/memory"

  let store: MemoryStoreBox
  let settings: MemorySettingsBox

  func handle(_ request: Request, path: String) async -> Response {
    guard let store = store.store else {
      return .jsonError(.notFound, type: "not_found", message: "Memory isn't available here.")
    }
    let rest = path.dropFirst(Self.prefix.count).split(separator: "/").map(String.init)

    do {
      switch (request.method, rest.count) {
      case (.get, 0):
        return .json(["settings": Self.json(settings.settings), "memories": await store.all().map(Self.json)])

      case (.post, 0):
        guard let text = await Self.body(request)?["text"] as? String else { return .badJSON }
        let (memory, isNew) = try await store.add(text, source: .user)
        return .json(["memory": Self.json(memory), "isNew": isNew], status: isNew ? .created : .ok)

      case (.delete, 0):
        try await store.deleteAll()
        return .json(["deleted": true])

      case (.patch, 1) where rest[0] == "settings":
        guard let body = await Self.body(request) else { return .badJSON }
        let updated = settings.update { value in
          if let enabled = body["enabled"] as? Bool { value.enabled = enabled }
        }
        return .json(Self.json(updated))

      case (.patch, 1):
        guard let text = await Self.body(request)?["text"] as? String else { return .badJSON }
        // Edited by the user, so it's theirs now.
        guard let memory = try await store.update(id: rest[0], text: text, source: .user) else {
          return .jsonError(.notFound, type: "not_found", message: "No such memory.")
        }
        return .json(Self.json(memory))

      case (.delete, 1):
        guard try await store.delete(id: rest[0]) else {
          return .jsonError(.notFound, type: "not_found", message: "No such memory.")
        }
        return .json(["deleted": true])

      default:
        return .jsonError(.notFound, type: "not_found", message: "No such memory endpoint.")
      }
    } catch let error as MemoryError {
      return .jsonError(.badRequest, type: "invalid_request_error", message: error.localizedDescription)
    } catch {
      return .jsonError(.internalServerError, type: "storage_error", message: "Couldn't save memories: \(error.localizedDescription)")
    }
  }

  static func json(_ memory: Memory) -> [String: Any] {
    let formatter = ISO8601DateFormatter()
    return [
      "id": memory.id, "text": memory.text, "source": memory.source.rawValue,
      "createdAt": formatter.string(from: memory.createdAt), "updatedAt": formatter.string(from: memory.updatedAt),
    ]
  }

  static func json(_ settings: MemorySettings) -> [String: Any] {
    ["enabled": settings.enabled]
  }

  private static func body(_ request: Request) async -> [String: Any]? {
    guard let buffer = try? await request.body.collect(upTo: 100_000) else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView))) as? [String: Any]
  }
}

// MARK: - Tools

/// "Remember that…": stores a fact the user stated.
public struct RememberTool: GatewayTool {
  let store: MemoryStore
  public init(store: MemoryStore) { self.store = store }

  public let name = "remember"
  public let description =
    "Save a lasting fact about the user so it's remembered in future chats. Use it when the user asks you to remember something, or states a lasting preference, like or dislike, or fact about themselves. Write one short sentence in the third person, e.g. \"Is vegetarian\" or \"Prefers answers in metric units\". Don't save one-off requests or anything secret."
  public let inputSchema: Value = .object([
    "type": .string("object"),
    "properties": .object([
      "text": .object([
        "type": .string("string"),
        "description": .string("The fact, one short third-person sentence."),
      ])
    ]),
    "required": .array([.string("text")]),
  ])

  public func call(arguments: [String: Value]) async throws -> String {
    guard let text = arguments["text"]?.stringValue else { throw MemoryError.empty }
    let (memory, isNew) = try await store.add(text, source: .user)
    return isNew ? "Remembered: \(memory.text)" : "Updated an existing memory: \(memory.text)"
  }
}

/// "Forget that…": removes the closest matching memory.
public struct ForgetTool: GatewayTool {
  let store: MemoryStore
  public init(store: MemoryStore) { self.store = store }

  public let name = "forget"
  public let description =
    "Delete a saved memory about the user when they ask you to forget something. Pass the memory's id (from recall_memories) or a description of it."
  public let inputSchema: Value = .object([
    "type": .string("object"),
    "properties": .object([
      "memory": .object([
        "type": .string("string"),
        "description": .string("The memory's id, or text describing it."),
      ])
    ]),
    "required": .array([.string("memory")]),
  ])

  public func call(arguments: [String: Value]) async throws -> String {
    guard let query = arguments["memory"]?.stringValue?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
      throw MemoryError.empty
    }
    let memories = await store.all()
    if let exact = memories.first(where: { $0.id == query }) {
      _ = try await store.delete(id: exact.id)
      return "Forgot: \(exact.text)"
    }
    let scored = memories
      .map { (memory: $0, score: Self.score(query, $0.text)) }
      .filter { $0.score >= 0.3 }
      .sorted { $0.score > $1.score }
    guard let best = scored.first else { return "No saved memory matches \"\(query)\"." }
    if scored.count > 1, scored[1].score > best.score - 0.1 {
      let options = scored.prefix(5).map { "- \($0.memory.text) (id: \($0.memory.id))" }.joined(separator: "\n")
      return "Several memories match. Ask the user which one to forget, then call forget with its id:\n\(options)"
    }
    _ = try await store.delete(id: best.memory.id)
    return "Forgot: \(best.memory.text)"
  }

  static func score(_ query: String, _ text: String) -> Double {
    if text.lowercased().contains(query.lowercased()) { return 1 }
    return MemoryText.similarity(query, text)
  }
}

/// "What do you know about me?"
public struct RecallMemoriesTool: GatewayTool {
  let store: MemoryStore
  public init(store: MemoryStore) { self.store = store }

  public let name = "recall_memories"
  public let description =
    "List everything saved about the user, with ids. Use it when the user asks what you know or remember about them, or before forgetting something."
  public let inputSchema: Value = .object(["type": .string("object"), "properties": .object([:])])

  public func call(arguments: [String: Value]) async throws -> String {
    let memories = await store.all().sorted { $0.updatedAt > $1.updatedAt }
    guard !memories.isEmpty else { return "Nothing is saved about the user yet." }
    let lines = memories.map { "- \($0.text) (\($0.source == .user ? "told by the user" : "learned"), id: \($0.id))" }
    return "Saved memories (\(memories.count)):\n" + lines.joined(separator: "\n")
  }
}
