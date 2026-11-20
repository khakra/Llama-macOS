import Foundation
import Security

// FORK: localchat gateway. Cloud provider API keys, one Keychain item per provider:
// service `app.localchat.provider`, account = provider ID (e.g. `openrouter`).
// Same item for Debug and Release builds, and for `security add-generic-password`.
enum ProviderKeychain {
  static let service = "app.localchat.provider"

  private static func query(_ providerID: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: providerID,
    ]
  }

  enum Read {
    case found(String)
    /// No key saved for this provider.
    case missing
    /// There is a key, but it couldn't be read: access denied, the "allow" prompt
    /// dismissed or timed out, or the Keychain locked.
    case failed(OSStatus)
  }

  static func read(_ providerID: String) -> Read {
    var query = query(providerID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else { return .failed(status) }
      return .found(key.trimmingCharacters(in: .whitespacesAndNewlines))
    case errSecItemNotFound:
      return .missing
    default:
      return .failed(status)
    }
  }

  @discardableResult
  static func setKey(_ key: String, for providerID: String) -> Bool {
    let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    let update = SecItemUpdate(query(providerID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if update == errSecSuccess { return true }
    guard update == errSecItemNotFound else { return false }
    var add = query(providerID)
    add[kSecValueData as String] = data
    add[kSecAttrLabel as String] = "LocalChat – \(providerID)"
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  static func deleteKey(for providerID: String) {
    SecItemDelete(query(providerID) as CFDictionary)
  }
}
