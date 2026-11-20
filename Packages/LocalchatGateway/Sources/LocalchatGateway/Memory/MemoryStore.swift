// FORK: localchat memory (docs/memory.md).
import Foundation

/// One fact about the user. Deliberately small: no kind, no pinning, no link
/// back to a conversation.
public struct Memory: Codable, Sendable, Equatable, Identifiable {
  public enum Source: String, Codable, Sendable {
    /// Stated by the user ("remember that…") or typed in Settings. Only the user changes these.
    case user
    /// Added by the background learner. The learner may update or remove only these.
    case learned
  }

  public var id: String
  public var text: String
  public var source: Source
  public var createdAt: Date
  public var updatedAt: Date
}

/// Where memories are kept. JSON today; SQLite later, when embeddings arrive.
public protocol MemoryStore: Sendable {
  func all() async -> [Memory]
  /// Adds a memory, or updates a near-duplicate instead (returned with `isNew == false`).
  func add(_ text: String, source: Memory.Source) async throws -> (memory: Memory, isNew: Bool)
  /// Changes the text. A memory the user edits becomes `source: user`.
  func update(id: String, text: String, source: Memory.Source) async throws -> Memory?
  func delete(id: String) async throws -> Bool
  func deleteAll() async throws
}

public enum MemoryError: Error, LocalizedError {
  case empty
  case tooLong(Int)

  public var errorDescription: String? {
    switch self {
    case .empty: return "A memory can't be empty."
    case .tooLong(let limit): return "A memory must be at most \(limit) characters."
    }
  }
}

/// `memory.json` in the app's data folder. Read once, kept in memory, written
/// atomically (temporary file, then rename) on every change.
public actor JSONMemoryStore: MemoryStore {
  public static let maxLength = 300

  private struct File: Codable {
    var version = 1
    var memories: [Memory] = []
  }

  private let url: URL
  private var memories: [Memory]

  public init(url: URL) {
    self.url = url
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let data = try? Data(contentsOf: url), let file = try? decoder.decode(File.self, from: data) {
      self.memories = file.memories
    } else {
      self.memories = []
    }
  }

  public func all() -> [Memory] { memories }

  public func add(_ text: String, source: Memory.Source) throws -> (memory: Memory, isNew: Bool) {
    let text = try Self.clean(text)
    let now = Date()
    if let index = memories.firstIndex(where: { MemoryText.isNearDuplicate($0.text, text) }) {
      // Same fact again: keep one, with the newer wording. A user statement
      // wins over a learned one, never the other way round.
      if source == .user || memories[index].source == .learned {
        memories[index].text = text
        memories[index].source = source == .user ? .user : memories[index].source
        memories[index].updatedAt = now
        try save()
      }
      return (memories[index], false)
    }
    let memory = Memory(id: UUID().uuidString.lowercased(), text: text, source: source, createdAt: now, updatedAt: now)
    memories.append(memory)
    try save()
    return (memory, true)
  }

  public func update(id: String, text: String, source: Memory.Source) throws -> Memory? {
    let text = try Self.clean(text)
    guard let index = memories.firstIndex(where: { $0.id == id }) else { return nil }
    memories[index].text = text
    memories[index].source = source
    memories[index].updatedAt = Date()
    try save()
    return memories[index]
  }

  public func delete(id: String) throws -> Bool {
    let before = memories.count
    memories.removeAll { $0.id == id }
    guard memories.count != before else { return false }
    try save()
    return true
  }

  public func deleteAll() throws {
    memories = []
    try save()
  }

  private func save() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(File(memories: memories))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  static func clean(_ text: String) throws -> String {
    let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty else { throw MemoryError.empty }
    guard collapsed.count <= maxLength else { throw MemoryError.tooLong(maxLength) }
    return collapsed
  }
}

/// Text helpers shared by the store, the tools and (step 2) the learner.
public enum MemoryText {
  static func words(_ text: String) -> Set<String> {
    Set(
      text.lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
        .filter { $0.count > 1 })
  }

  /// Jaccard similarity of the two texts' word sets (0...1).
  public static func similarity(_ a: String, _ b: String) -> Double {
    let left = words(a), right = words(b)
    guard !left.isEmpty || !right.isEmpty else { return 1 }
    return Double(left.intersection(right).count) / Double(left.union(right).count)
  }

  /// Same fact, slightly different wording. Threshold from osaurus's dedup.
  public static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
    similarity(a, b) >= 0.6
  }
}
