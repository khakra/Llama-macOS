import Foundation
import LocalchatGateway
import MCP

// FORK: localchat gateway. Tells the model which LocalChat and engine it runs on,
// and which local and cloud models are available. The first tool on `/mcp`.
struct LocalchatInfoTool: GatewayTool {
  let name = "localchat_info"
  let description =
    "Get information about this LocalChat app: its version, the local engine, and which local and cloud models are available (and which local ones are loaded). Use it when the user asks about the app or their models."
  let inputSchema: Value = .object(["type": .string("object"), "properties": .object([:])])

  func call(arguments: [String: Value]) async throws -> String {
    await MainActor.run {
      var lines = ["LocalChat \(AppInfo.shortVersion) (build \(AppInfo.buildNumber))"]
      if let engine = LlamaInstallManager.shared.currentVersion {
        lines.append("Local engine: llama.cpp \(engine)")
      }

      let statuses = LlamaServer.shared.modelStatuses
      let local = ModelManager.shared.downloadedModels
      lines.append("")
      lines.append(local.isEmpty ? "Local models: none downloaded." : "Local models (\(local.count)):")
      for model in local.sorted(by: { $0.displayName < $1.displayName }) {
        let state = statuses[model.id]?.rawValue ?? "unloaded"
        lines.append("- \(model.displayName) [\(model.id)] — \(state)")
      }

      let cloud = CloudSettings.shared.activeProviders()
      lines.append("")
      if cloud.isEmpty {
        lines.append("Cloud models: none enabled.")
      } else {
        lines.append("Cloud models:")
        for provider in cloud {
          for model in provider.models {
            lines.append("- \(model) via \(provider.displayName) [\(CloudModelID.make(provider: provider.id, model: model))]")
          }
        }
      }
      return lines.joined(separator: "\n")
    }
  }
}
