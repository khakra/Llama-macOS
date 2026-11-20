import Foundation
import LocalchatGateway

// FORK: localchat memory (docs/memory.md). Where memories live and how their
// settings are saved; the gateway does the rest.
enum MemorySetup {
  private static let enabledKey = "memoryEnabled"
  private static let withCloudKey = "memoryWithCloud"

  /// `~/Library/Application Support/LocalChat/memory.json`
  static let store = JSONMemoryStore(url: UserSettings.appSupportDir.appendingPathComponent("memory.json"))

  /// Both on by default: memories are used in chats, cloud models included.
  static var settings: MemorySettings {
    let defaults = UserDefaults.standard
    return MemorySettings(
      enabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
      withCloud: defaults.object(forKey: withCloudKey) as? Bool ?? true)
  }

  static func save(_ settings: MemorySettings) {
    let defaults = UserDefaults.standard
    defaults.set(settings.enabled, forKey: enabledKey)
    defaults.set(settings.withCloud, forKey: withCloudKey)
  }

  static func configure(_ gateway: Gateway) {
    gateway.configureMemory(store: store, settings: settings, persist: { save($0) })
  }

  static var tools: [GatewayTool] {
    [RememberTool(store: store), ForgetTool(store: store), RecallMemoriesTool(store: store)]
  }
}
