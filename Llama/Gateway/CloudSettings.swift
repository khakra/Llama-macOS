import Foundation
import LocalchatGateway
import os.log

// FORK: localchat gateway. Which cloud providers are on (edited in the chat UI's Settings › Cloud) and which of their models
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
  /// Keys read from the Keychain this session. Reading may show macOS's "allow"
  /// prompt, so a successful read (or a confirmed "no key") is kept in memory. A
  /// failed read isn't, so the next use asks again instead of reporting no key
  /// until the app restarts.
  private var keys: [String: String?] = [:]
  private let logger = Logger(subsystem: Logging.subsystem, category: "CloudSettings")

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
    switch ProviderKeychain.read(preset.id) {
    case .found(let key):
      keys[preset.id] = key
      // A retry after a failed read (e.g. the user allowed access in the prompt):
      // the gateway didn't have this provider yet.
      if !pushing { pushToGateway() }
      return key
    case .missing:
      keys[preset.id] = .some(nil)
      return nil
    case .failed(let status):
      logger.error("couldn't read the \(preset.id, privacy: .public) key from the Keychain (status \(status))")
      return nil
    }
  }

  /// Stores (or removes) the key. Returns false if the Keychain refused.
  @discardableResult
  func setKey(_ key: String?, for preset: CloudProviderPreset) -> Bool {
    var ok = true
    if let key, !key.isEmpty {
      ok = ProviderKeychain.setKey(key, for: preset.id)
      if ok { keys[preset.id] = key.trimmingCharacters(in: .whitespacesAndNewlines) }
    } else {
      ProviderKeychain.deleteKey(for: preset.id)
      keys[preset.id] = .some(nil)
    }
    objectWillChange.send()
    pushToGateway()
    return ok
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

  private var pushing = false

  func pushToGateway() {
    pushing = true
    defer { pushing = false }
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

// FORK: localchat gateway. Lets the chat UI's Cloud settings (via /localchat/cloud/...)
// read and change these settings. Keys go in, never out.
struct AppCloudSettingsBackend: CloudSettingsBackend {
  func statuses() async -> [CloudProviderStatus] {
    await MainActor.run {
      let settings = CloudSettings.shared
      return CloudProviderPreset.all.map { preset in
        let entry = settings.settings(for: preset)
        return CloudProviderStatus(
          preset: preset, enabled: entry.enabled,
          hasKey: !(settings.key(for: preset)?.isEmpty ?? true), models: entry.models)
      }
    }
  }

  func update(providerID: String, enabled: Bool?, models: [String]?) async -> CloudProviderStatus? {
    await MainActor.run {
      guard let preset = CloudProviderPreset.named(providerID) else { return nil }
      let settings = CloudSettings.shared
      settings.update(preset) { entry in
        if let enabled { entry.enabled = enabled }
        if let models { entry.models = models }
      }
      let entry = settings.settings(for: preset)
      return CloudProviderStatus(
        preset: preset, enabled: entry.enabled,
        hasKey: !(settings.key(for: preset)?.isEmpty ?? true), models: entry.models)
    }
  }

  func setKey(providerID: String, key: String?) async -> Bool {
    await MainActor.run {
      guard let preset = CloudProviderPreset.named(providerID) else { return false }
      return CloudSettings.shared.setKey(key, for: preset)
    }
  }

  func provider(providerID: String) async -> CloudProvider? {
    await MainActor.run {
      CloudProviderPreset.named(providerID).map { CloudSettings.shared.provider(for: $0) }
    }
  }
}
