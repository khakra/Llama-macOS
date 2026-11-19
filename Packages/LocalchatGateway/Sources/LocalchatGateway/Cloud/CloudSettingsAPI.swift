// FORK: localchat gateway.
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// One provider as the settings screen sees it. Never carries the key itself.
public struct CloudProviderStatus: Sendable {
  public var preset: CloudProviderPreset
  public var enabled: Bool
  public var hasKey: Bool
  public var models: [String]

  public init(preset: CloudProviderPreset, enabled: Bool, hasKey: Bool, models: [String]) {
    self.preset = preset
    self.enabled = enabled
    self.hasKey = hasKey
    self.models = models
  }

  var json: [String: Any] {
    var object: [String: Any] = [
      "id": preset.id,
      "name": preset.displayName,
      "host": preset.baseURL.host() ?? preset.baseURL.absoluteString,
      "local": !preset.needsKey,
      "needsKey": preset.needsKey,
      "enabled": enabled,
      "hasKey": hasKey,
      "models": models,
    ]
    if let keyURL = preset.keyURL { object["keyURL"] = keyURL.absoluteString }
    return object
  }
}

/// Where cloud settings live: the app (`defaults` plus the Keychain).
public protocol CloudSettingsBackend: Sendable {
  func statuses() async -> [CloudProviderStatus]
  /// Changes `enabled` and/or the chosen models. Returns the new status, or nil for an unknown provider.
  func update(providerID: String, enabled: Bool?, models: [String]?) async -> CloudProviderStatus?
  /// Stores (or with nil, removes) the key. Returns false for an unknown provider or a Keychain failure.
  func setKey(providerID: String, key: String?) async -> Bool
  /// The provider with its key, enabled or not (for listing its models and testing).
  func provider(providerID: String) async -> CloudProvider?
}

/// `/localchat/cloud/...`: the settings API behind the chat UI's Cloud section.
///
/// Keys are write-only: they come in once (PUT .../key) and go straight to the
/// Keychain. No endpoint ever returns one. Same access rule as cloud chat:
/// clients on this Mac, from the gateway's own page.
struct CloudSettingsAPI: Sendable {
  static let prefix = "/localchat/cloud/providers"

  let backend: @Sendable () -> CloudSettingsBackend?

  func handle(_ request: Request, path: String) async -> Response {
    guard let backend = backend() else {
      return .jsonError(.notFound, type: "not_found", message: "Cloud settings aren't available here.")
    }
    let rest = path.dropFirst(Self.prefix.count).split(separator: "/").map(String.init)

    switch (request.method, rest.count) {
    case (.get, 0):
      let statuses = await backend.statuses()
      return .json(["providers": statuses.map(\.json)])

    case (.patch, 1):
      guard let body = await Self.jsonBody(request) else { return .badJSON }
      let enabled = body["enabled"] as? Bool
      let models = (body["models"] as? [Any])?.compactMap { $0 as? String }
      guard let status = await backend.update(providerID: rest[0], enabled: enabled, models: models) else {
        return .unknownProvider(rest[0])
      }
      return .json(status.json)

    case (.put, 2) where rest[1] == "key":
      guard let body = await Self.jsonBody(request), let key = body["key"] as? String,
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return .badJSON }
      guard await backend.setKey(providerID: rest[0], key: key) else {
        return .jsonError(.internalServerError, type: "keychain_error", message: "Couldn't save the key to the Keychain.")
      }
      return .json(["hasKey": true])

    case (.delete, 2) where rest[1] == "key":
      guard await backend.setKey(providerID: rest[0], key: nil) else { return .unknownProvider(rest[0]) }
      return .json(["hasKey": false])

    case (.get, 2) where rest[1] == "models":
      guard let provider = await backend.provider(providerID: rest[0]) else { return .unknownProvider(rest[0]) }
      do {
        let models = try await CloudCatalog.fetch(provider)
        return .json([
          "models": models.map { model -> [String: Any] in
            [
              "id": model.id, "name": model.name ?? model.id, "contextLength": model.contextLength ?? 0,
              "vision": model.vision, "reasoning": model.reasoning,
            ]
          }
        ])
      } catch {
        return .jsonError(.badGateway, type: "upstream_error", message: error.localizedDescription)
      }

    case (.post, 2) where rest[1] == "test":
      guard let provider = await backend.provider(providerID: rest[0]) else { return .unknownProvider(rest[0]) }
      do {
        let count = try await CloudCatalog.test(provider)
        return .json(["ok": true, "message": "Connected. \(count) models available."])
      } catch {
        return .json(["ok": false, "message": error.localizedDescription])
      }

    default:
      return .jsonError(.notFound, type: "not_found", message: "No such cloud settings endpoint.")
    }
  }

  private static func jsonBody(_ request: Request) async -> [String: Any]? {
    guard let buffer = try? await request.body.collect(upTo: 1_000_000) else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView))) as? [String: Any]
  }
}

/// Holds the app's settings backend; set once the app is ready.
final class CloudSettingsBackendBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: CloudSettingsBackend?
  var backend: CloudSettingsBackend? { lock.withLock { value } }
  func set(_ backend: CloudSettingsBackend?) { lock.withLock { value = backend } }
}

extension Response {
  static var badJSON: Response {
    jsonError(.badRequest, type: "invalid_request_error", message: "Expected a JSON body.")
  }

  static func unknownProvider(_ id: String) -> Response {
    jsonError(.notFound, type: "not_found", message: "Unknown cloud provider \(id).")
  }
}
