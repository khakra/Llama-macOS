// FORK: localchat gateway.
import Foundation

/// A cloud provider the gateway can route to, with everything needed to call it.
/// The app builds these from presets, its settings and the Keychain.
public struct CloudProvider: Sendable, Equatable {
  public var id: String
  public var displayName: String
  /// OpenAI-compatible base, e.g. `https://openrouter.ai/api/v1`.
  public var baseURL: URL
  public var apiKey: String?
  /// Provider model IDs the user chose to show, e.g. `anthropic/claude-sonnet-4.5`.
  public var models: [String]
  public var preset: CloudProviderPreset

  public init(preset: CloudProviderPreset, apiKey: String?, models: [String], baseURL: URL? = nil) {
    self.id = preset.id
    self.displayName = preset.displayName
    self.baseURL = baseURL ?? preset.baseURL
    self.apiKey = apiKey
    self.models = models
    self.preset = preset
  }

  func url(_ path: String) -> URL {
    baseURL.appendingPathComponent(path)
  }

  /// Headers for every request to this provider. Never logged.
  var requestHeaders: [String: String] {
    var headers = preset.extraHeaders
    if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
    return headers
  }
}

/// A known provider. Phase 1: all speak OpenAI's chat completions format.
public struct CloudProviderPreset: Sendable, Equatable, Identifiable {
  public var id: String
  public var displayName: String
  public var baseURL: URL
  public var needsKey: Bool
  /// Where users get a key, shown in Settings.
  public var keyURL: URL?
  /// Sampling parameters this provider accepts beyond the OpenAI set.
  public var extraParameters: Set<String>
  /// OpenAI wants `max_completion_tokens` instead of `max_tokens`.
  public var usesMaxCompletionTokens: Bool
  /// OpenRouter takes `reasoning: {effort}` instead of `reasoning_effort`.
  public var nestedReasoning: Bool
  public var extraHeaders: [String: String]

  public static let openRouter = CloudProviderPreset(
    id: "openrouter", displayName: "OpenRouter",
    baseURL: URL(string: "https://openrouter.ai/api/v1")!, needsKey: true,
    keyURL: URL(string: "https://openrouter.ai/settings/keys"),
    extraParameters: ["top_k", "min_p", "top_a", "repetition_penalty"],
    usesMaxCompletionTokens: false, nestedReasoning: true,
    extraHeaders: ["HTTP-Referer": "https://localchat.app", "X-Title": "LocalChat"])

  public static let openAI = CloudProviderPreset(
    id: "openai", displayName: "OpenAI",
    baseURL: URL(string: "https://api.openai.com/v1")!, needsKey: true,
    keyURL: URL(string: "https://platform.openai.com/api-keys"),
    extraParameters: [], usesMaxCompletionTokens: true, nestedReasoning: false, extraHeaders: [:])

  public static let gemini = CloudProviderPreset(
    id: "gemini", displayName: "Google Gemini",
    baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!, needsKey: true,
    keyURL: URL(string: "https://aistudio.google.com/apikey"),
    extraParameters: [], usesMaxCompletionTokens: false, nestedReasoning: false, extraHeaders: [:])

  public static let groq = CloudProviderPreset(
    id: "groq", displayName: "Groq",
    baseURL: URL(string: "https://api.groq.com/openai/v1")!, needsKey: true,
    keyURL: URL(string: "https://console.groq.com/keys"),
    extraParameters: [], usesMaxCompletionTokens: false, nestedReasoning: false, extraHeaders: [:])

  public static let xAI = CloudProviderPreset(
    id: "xai", displayName: "xAI",
    baseURL: URL(string: "https://api.x.ai/v1")!, needsKey: true,
    keyURL: URL(string: "https://console.x.ai"),
    extraParameters: [], usesMaxCompletionTokens: false, nestedReasoning: false, extraHeaders: [:])

  public static let ollama = CloudProviderPreset(
    id: "ollama", displayName: "Ollama",
    baseURL: URL(string: "http://localhost:11434/v1")!, needsKey: false, keyURL: nil,
    extraParameters: ["top_k", "min_p", "repeat_penalty"],
    usesMaxCompletionTokens: false, nestedReasoning: false, extraHeaders: [:])

  public static let lmStudio = CloudProviderPreset(
    id: "lmstudio", displayName: "LM Studio",
    baseURL: URL(string: "http://localhost:1234/v1")!, needsKey: false, keyURL: nil,
    extraParameters: ["top_k", "min_p", "repeat_penalty"],
    usesMaxCompletionTokens: false, nestedReasoning: false, extraHeaders: [:])

  public static let all: [CloudProviderPreset] = [openRouter, openAI, gemini, groq, xAI, ollama, lmStudio]

  public static func named(_ id: String) -> CloudProviderPreset? { all.first { $0.id == id } }
}
