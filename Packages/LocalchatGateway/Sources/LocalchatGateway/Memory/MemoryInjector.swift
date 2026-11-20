// FORK: localchat memory (docs/memory.md).
import Foundation

/// Memory settings the gateway needs on every request. Stored by the app.
public struct MemorySettings: Sendable, Equatable {
  /// Master switch: use memories in chats (and keep the tools working).
  public var enabled: Bool
  /// Also add memories when chatting with cloud models.
  public var withCloud: Bool

  public init(enabled: Bool = true, withCloud: Bool = true) {
    self.enabled = enabled
    self.withCloud = withCloud
  }
}

/// Adds the "About the user" block to the system prompt of a chat request.
///
/// System prompt rather than the latest user message: the UI resends the whole
/// history each turn and the engine reuses its cache for the longest unchanged
/// prefix, which a stable system prompt keeps intact.
public enum MemoryInjector {
  public static let budget = 3_000  // characters, about 800 tokens

  static let header = """
    ## About the user
    Things the user has told you or that you've learned in earlier chats. Use them when relevant; \
    don't mention them unless asked. The user's own words take priority over these.
    """

  /// The block for these memories: the user's own first, then learned ones
  /// newest first, within the budget. Nil when there's nothing to add.
  public static func block(for memories: [Memory]) -> String? {
    let ordered =
      memories.filter { $0.source == .user }.sorted { $0.updatedAt > $1.updatedAt }
      + memories.filter { $0.source == .learned }.sorted { $0.updatedAt > $1.updatedAt }
    var lines: [String] = []
    var used = header.count
    for memory in ordered {
      let line = "- \(memory.text)"
      if used + line.count + 1 > budget { break }
      lines.append(line)
      used += line.count + 1
    }
    guard !lines.isEmpty else { return nil }
    return header + "\n" + lines.joined(separator: "\n")
  }

  /// Returns `body` with the block appended to its first system message (or a
  /// new system message in front). Unchanged when there's no block or no messages.
  public static func inject(_ block: String?, into body: [String: Any]) -> [String: Any] {
    guard let block, var messages = body["messages"] as? [[String: Any]] else { return body }
    var body = body
    if let index = messages.firstIndex(where: { ($0["role"] as? String) == "system" }) {
      var system = messages[index]
      switch system["content"] {
      case let text as String:
        system["content"] = text.isEmpty ? block : text + "\n\n" + block
      case var parts as [[String: Any]]:
        parts.append(["type": "text", "text": block])
        system["content"] = parts
      default:
        system["content"] = block
      }
      messages[index] = system
    } else {
      messages.insert(["role": "system", "content": block], at: 0)
    }
    body["messages"] = messages
    return body
  }
}

/// Settings plus a way to persist them (the app saves to `defaults`).
final class MemorySettingsBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value = MemorySettings()
  private var persist: (@Sendable (MemorySettings) -> Void)?

  var settings: MemorySettings { lock.withLock { value } }

  func configure(_ settings: MemorySettings, persist: @escaping @Sendable (MemorySettings) -> Void) {
    lock.withLock {
      value = settings
      self.persist = persist
    }
  }

  func update(_ change: (inout MemorySettings) -> Void) -> MemorySettings {
    let (updated, persist) = lock.withLock { () -> (MemorySettings, (@Sendable (MemorySettings) -> Void)?) in
      change(&value)
      return (value, self.persist)
    }
    persist?(updated)
    return updated
  }
}

/// Holds the store once the app provides it.
final class MemoryStoreBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: MemoryStore?
  var store: MemoryStore? { lock.withLock { value } }
  func set(_ store: MemoryStore?) { lock.withLock { value = store } }
}
