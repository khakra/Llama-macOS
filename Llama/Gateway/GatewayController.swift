import Foundation
import LocalchatGateway
import os.log

// FORK: localchat gateway (docs/gateway.md in khakra/localchat).
/// Runs the gateway on the user-facing port, in front of the engine on `EnginePort.current`.
/// `LlamaServer.start()` calls `ensureRunning()` before every engine launch, so a
/// port or network setting change rebinds the gateway along with the engine restart.
@MainActor
final class GatewayController {
  static let shared = GatewayController()

  private let logger = Logger(subsystem: Logging.subsystem, category: "Gateway")
  private let gateway = Gateway(engine: { EngineEndpoint(port: EnginePort.current) })
  private var running: GatewayConfiguration?

  /// Listens where the engine used to: loopback, or the Network setting's address
  /// (plus loopback). Host checks apply only while loopback is all we serve.
  func desiredConfiguration() -> GatewayConfiguration {
    let bindAddress = LlamaServer.effectiveBindAddress
    let addresses = bindAddress.map { LlamaServer.boundAddresses(for: $0) } ?? ["127.0.0.1"]
    return GatewayConfiguration(
      addresses: addresses,
      port: LlamaServer.port,
      hostPolicy: HostPolicy(loopbackOnly: bindAddress == nil || bindAddress == "127.0.0.1"))
  }

  /// Hands the gateway the cloud providers to route to. Takes effect on the next request.
  func setCloudProviders(_ providers: [CloudProvider]) {
    gateway.setCloudProviders(providers)
  }

  /// Starts the gateway, or rebinds it if its settings changed. Returns nil once
  /// it's listening, or the name of whatever holds the port.
  func ensureRunning() async -> String? {
    let configuration = desiredConfiguration()
    if configuration == running { return nil }

    await gateway.stop()
    running = nil

    // An engine from before the gateway, or one orphaned by a crash, may still hold the user port.
    let port = configuration.port
    let blocker = await Task.detached { LlamaServer.reclaimPort(port) }.value

    do {
      try await gateway.start(configuration)
      running = configuration
      CloudSettings.shared.pushToGateway()
      logger.info(
        "listening on \(configuration.addresses.joined(separator: ","), privacy: .public) port \(port)")
      return nil
    } catch {
      logger.error("couldn't listen on port \(port): \(error.localizedDescription, privacy: .public)")
      return blocker ?? "another process"
    }
  }
}
