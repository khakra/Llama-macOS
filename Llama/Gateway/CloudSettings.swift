import Foundation
import LocalchatGateway

// FORK: localchat gateway. Which cloud providers are on and which of their models
// to show. Settings live in `defaults` (`cloudProviders`); keys in the Keychain.
@MainActor
final class CloudSettings: ObservableObject {
  static let shared = CloudSettings()

  struct Stored: Codable, Equatable {
    var id: String
    var enabled: Bool
    var models: [String]
  }

  private static let defaultsKey = "cloudProviders"

  @Published private(set) var stored: [String: Stored] = [:]
  /// Keys read from the Keychain this session. Reading prompts the first time,
  /// so each key is read once and then kept in memory.
  private var keys: [String: String?] = [:]

  private init() {
    if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
      let list = try? JSONDecoder().decode([Stored].self, from: data)
    {
      stored = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }
  }

  func settings(for preset: CloudProviderPreset) -> Stored {
    stored[preset.id] ?? Stored(id: preset.id, enabled: false, models: [])
  }

  func update(_ preset: CloudProviderPreset, _ change: (inout Stored) -> Void) {
    var entry = settings(for: preset)
    change(&entry)
    stored[preset.id] = entry
    save()
  }

  func key(for preset: CloudProviderPreset) -> String? {
    if let cached = keys[preset.id] { return cached }
    let key = ProviderKeychain.key(for: preset.id)
    keys[preset.id] = key
    return key
  }

  func setKey(_ key: String?, for preset: CloudProviderPreset) {
    if let key, !key.isEmpty {
      ProviderKeychain.setKey(key, for: preset.id)
      keys[preset.id] = key
    } else {
      ProviderKeychain.deleteKey(for: preset.id)
      keys[preset.id] = .some(nil)
    }
    objectWillChange.send()
    pushToGateway()
  }

  /// A provider as the gateway needs it, whether or not it's enabled (for Test and the model picker).
  func provider(for preset: CloudProviderPreset) -> CloudProvider {
    CloudProvider(preset: preset, apiKey: key(for: preset), models: settings(for: preset).models)
  }

  /// Enabled providers that are ready to use: a key if they need one, and at least one model.
  func activeProviders() -> [CloudProvider] {
    CloudProviderPreset.all.compactMap { preset in
      let entry = settings(for: preset)
      guard entry.enabled, !entry.models.isEmpty else { return nil }
      let provider = provider(for: preset)
      if preset.needsKey, provider.apiKey?.isEmpty ?? true { return nil }
      return provider
    }
  }

  func pushToGateway() {
    GatewayController.shared.setCloudProviders(activeProviders())
  }

  private func save() {
    let list = stored.values.sorted { $0.id < $1.id }
    if let data = try? JSONEncoder().encode(list) {
      UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
    pushToGateway()
  }
}
