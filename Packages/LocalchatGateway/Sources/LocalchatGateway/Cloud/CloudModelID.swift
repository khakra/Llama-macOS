// FORK: localchat gateway.

/// Cloud model IDs as clients see them: `cloud@<provider>/<model>`, for example
/// `cloud@openrouter/anthropic/claude-sonnet-4.5`.
///
/// A Hugging Face org can't contain `@`, so these never collide with local
/// model IDs. A colon isn't used: the UI reads everything after the first `:`
/// as a quantization.
public enum CloudModelID {
  public static let prefix = "cloud@"

  public static func make(provider: String, model: String) -> String {
    "\(prefix)\(provider)/\(model)"
  }

  /// `("openrouter", "anthropic/claude-sonnet-4.5")`, or nil for a non-cloud ID.
  public static func parse(_ id: String) -> (provider: String, model: String)? {
    guard id.hasPrefix(prefix) else { return nil }
    let rest = id.dropFirst(prefix.count)
    guard let slash = rest.firstIndex(of: "/") else { return nil }
    let provider = String(rest[..<slash])
    let model = String(rest[rest.index(after: slash)...])
    guard !provider.isEmpty, !model.isEmpty else { return nil }
    return (provider, model)
  }

  public static func isCloud(_ id: String) -> Bool { id.hasPrefix(prefix) }
}
