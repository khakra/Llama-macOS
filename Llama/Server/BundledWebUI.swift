import Foundation

// FORK: localchat ships its own web UI inside the app (Contents/Resources/WebUI),
// copied there at build time by scripts/bundle-webui.sh.
enum BundledWebUI {
  /// The bundled web UI folder, or nil if this build has none (for example a
  /// Debug build made before the UI was built). The server then falls back to
  /// the UI built into the `llama` binary.
  nonisolated static var directory: URL? {
    guard let dir = Bundle.main.resourceURL?.appendingPathComponent("WebUI", isDirectory: true),
      LlamaServer.hasIndexPage(dir)
    else { return nil }
    return dir
  }
}
