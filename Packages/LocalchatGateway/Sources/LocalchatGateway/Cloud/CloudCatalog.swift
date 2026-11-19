// FORK: localchat gateway.
import Foundation

/// What we know about a cloud model: from the provider's `/models` where it
/// says (OpenRouter is detailed), else from `CloudModelInfo.guess`.
public struct CloudModelInfo: Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String?
  public var contextLength: Int?
  /// `text`, plus `image` for vision models.
  public var inputModalities: [String]
  public var reasoning: Bool

  public init(id: String, name: String? = nil, contextLength: Int? = nil, inputModalities: [String] = ["text"], reasoning: Bool = false) {
    self.id = id
    self.name = name
    self.contextLength = contextLength
    self.inputModalities = inputModalities
    self.reasoning = reasoning
  }

  public var vision: Bool { inputModalities.contains("image") }

  /// Best guess for providers whose `/models` carries no metadata (OpenAI, Groq, xAI).
  /// The UI uses it to size the context gauge and to allow image attachments.
  public static func guess(provider: String, model: String) -> CloudModelInfo {
    let m = model.lowercased()
    var info = CloudModelInfo(id: model)
    func has(_ prefixes: String...) -> Bool { prefixes.contains { m.hasPrefix($0) || m.contains("/\($0)") } }

    if has("gpt-5") {
      info.contextLength = 400_000; info.inputModalities = ["text", "image"]; info.reasoning = true
    } else if has("o1", "o3", "o4") {
      info.contextLength = 200_000; info.inputModalities = ["text", "image"]; info.reasoning = true
    } else if has("gpt-4.1") {
      info.contextLength = 1_047_576; info.inputModalities = ["text", "image"]
    } else if has("gpt-4o") {
      info.contextLength = 128_000; info.inputModalities = ["text", "image"]
    } else if has("gemini-") {
      info.contextLength = 1_048_576; info.inputModalities = ["text", "image"]
      info.reasoning = m.contains("2.5") || m.contains("-3")
    } else if has("claude-") {
      info.contextLength = 200_000; info.inputModalities = ["text", "image"]
      info.reasoning = !m.contains("haiku")
    } else if has("grok-4") {
      info.contextLength = 256_000; info.inputModalities = ["text", "image"]; info.reasoning = true
    } else if has("grok-") {
      info.contextLength = 131_072
    } else {
      info.contextLength = 131_072
    }
    return info
  }
}

/// Fetches and caches each provider's model list.
public actor CloudCatalog {
  public static let shared = CloudCatalog()

  private struct Entry {
    let models: [String: CloudModelInfo]
    let fetched: Date
    let ok: Bool
  }

  private var cache: [String: Entry] = [:]
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  /// Model details for `provider`, keyed by provider model ID. Never throws:
  /// on failure it returns what's cached, or nothing, and the caller falls back to guesses.
  func models(for provider: CloudProvider) async -> [String: CloudModelInfo] {
    let key = cacheKey(provider)
    if let entry = cache[key], Date().timeIntervalSince(entry.fetched) < (entry.ok ? 30 * 60 : 60) {
      return entry.models
    }
    do {
      let list = try await Self.fetch(provider, session: session, timeout: 5)
      let models = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      cache[key] = Entry(models: models, fetched: Date(), ok: true)
      return models
    } catch {
      let stale = cache[key]?.models ?? [:]
      cache[key] = Entry(models: stale, fetched: Date(), ok: false)
      return stale
    }
  }

  /// One model's details: from the provider's list, else guessed.
  func info(provider: CloudProvider, model: String) async -> CloudModelInfo {
    let listed = await models(for: provider)[model]
    let guess = CloudModelInfo.guess(provider: provider.id, model: model)
    guard var info = listed else { return guess }
    if info.contextLength == nil { info.contextLength = guess.contextLength }
    return info
  }

  public func invalidate(providerID: String) {
    cache = cache.filter { !$0.key.hasPrefix(providerID + "|") }
  }

  private func cacheKey(_ provider: CloudProvider) -> String {
    "\(provider.id)|\(provider.baseURL.absoluteString)|\(provider.apiKey?.hashValue ?? 0)"
  }

  /// The provider's full model list (for the settings picker and the Test button).
  /// Throws `CloudError` with a message fit for the user.
  public static func fetch(_ provider: CloudProvider, session: URLSession = .shared, timeout: TimeInterval = 15) async throws -> [CloudModelInfo] {
    var request = URLRequest(url: provider.url("models"), timeoutInterval: timeout)
    for (name, value) in provider.requestHeaders { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw CloudError.unreachable(provider.displayName, error.localizedDescription)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw CloudError.http(provider.displayName, status, CloudError.message(from: data))
    }
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let entries = root["data"] as? [[String: Any]]
    else { throw CloudError.unexpected(provider.displayName) }

    return entries.compactMap { entry in
      guard let rawID = entry["id"] as? String else { return nil }
      // Gemini lists "models/gemini-2.5-pro" but takes "gemini-2.5-pro" in requests.
      let id = rawID.hasPrefix("models/") ? String(rawID.dropFirst("models/".count)) : rawID
      var info = CloudModelInfo.guess(provider: provider.id, model: id)
      info.name = (entry["name"] as? String) ?? (entry["display_name"] as? String)
      if let length = entry["context_length"] as? Int { info.contextLength = length }
      if let architecture = entry["architecture"] as? [String: Any],
        let inputs = architecture["input_modalities"] as? [String]
      {
        info.inputModalities = inputs.contains("image") ? ["text", "image"] : ["text"]
      }
      if let supported = entry["supported_parameters"] as? [String] {
        info.reasoning = supported.contains("reasoning") || supported.contains("include_reasoning")
      }
      return info
    }
    .sorted { ($0.name ?? $0.id).localizedCaseInsensitiveCompare($1.name ?? $1.id) == .orderedAscending }
  }
}

extension CloudCatalog {
  /// Checks the provider is reachable and accepts the key. Returns how many models it offers.
  /// OpenRouter's `/models` is public, so its key is checked against `/key` first.
  public static func test(_ provider: CloudProvider, session: URLSession = .shared) async throws -> Int {
    if provider.id == CloudProviderPreset.openRouter.id {
      var request = URLRequest(url: provider.url("key"), timeoutInterval: 15)
      for (name, value) in provider.requestHeaders { request.setValue(value, forHTTPHeaderField: name) }
      let (data, response): (Data, URLResponse)
      do {
        (data, response) = try await session.data(for: request)
      } catch {
        throw CloudError.unreachable(provider.displayName, error.localizedDescription)
      }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(status) else {
        throw CloudError.http(provider.displayName, status, CloudError.message(from: data))
      }
    }
    return try await fetch(provider, session: session).count
  }
}

public enum CloudError: Error, LocalizedError, Equatable {
  case unreachable(String, String)
  case http(String, Int, String?)
  case unexpected(String)

  public var errorDescription: String? {
    switch self {
    case .unreachable(let provider, let detail):
      return "Couldn't reach \(provider): \(detail)"
    case .http(let provider, let status, let message):
      if status == 401 || status == 403 {
        return "\(provider) rejected the API key. Check it in Settings › Cloud."
      }
      return "\(provider) returned an error (\(status))" + (message.map { ": \($0)" } ?? ".")
    case .unexpected(let provider):
      return "\(provider) sent a response LocalChat doesn't understand."
    }
  }

  /// `error.message` from an OpenAI-style error body, if there is one.
  static func message(from data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let error = root["error"] as? [String: Any], let message = error["message"] as? String { return message }
    if let error = root["error"] as? String { return error }
    return root["message"] as? String
  }
}
