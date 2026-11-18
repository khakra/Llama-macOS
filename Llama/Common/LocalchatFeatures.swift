// FORK: localchat feature switches for upstream UI we don't offer.
enum LocalchatFeatures {
  /// "Sign in with Hugging Face" needs an HF OAuth app whose redirect URI uses our
  /// `localchat://` scheme. We don't have one, so Settings offers only a pasted token.
  static let hfSignIn = false

  /// Upstream's "Source code" link to ggml-org/Llama-macOS at the foot of the Settings sidebar.
  static let sourceCodeLink = false
}
