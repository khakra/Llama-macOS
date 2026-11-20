import Foundation
import LocalchatGateway

// FORK: localchat memory (docs/memory.md). Where memories live and how their
// settings are saved; the gateway does the rest.
enum MemorySetup {
  private static let enabledKey = "memoryEnabled"

  /// `~/Library/Application Support/LocalChat/memory.json`
  static let store = JSONMemoryStore(url: UserSettings.appSupportDir.appendingPathComponent("memory.json"))

  /// On by default: memories are used in chats with every model.
  static var settings: MemorySettings {
    MemorySettings(enabled: UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true)
  }

  static func save(_ settings: MemorySettings) {
    UserDefaults.standard.set(settings.enabled, forKey: enabledKey)
  }

  static func configure(_ gateway: Gateway) {
    gateway.configureMemory(store: store, settings: settings, persist: { save($0) })
  }

  static var tools: [GatewayTool] {
    [RememberTool(store: store), ForgetTool(store: store), RecallMemoriesTool(store: store)]
  }
}
