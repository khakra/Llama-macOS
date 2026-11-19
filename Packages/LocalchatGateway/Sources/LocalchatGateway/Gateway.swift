// FORK: localchat gateway (see docs/gateway.md in khakra/localchat).
import Foundation
import Hummingbird
import Logging
import NIOCore

/// Where and how the gateway listens.
public struct GatewayConfiguration: Sendable, Equatable {
  /// Addresses to bind, e.g. `["127.0.0.1"]`, `["0.0.0.0"]`, or loopback plus a LAN address.
  public var addresses: [String]
  public var port: Int
  public var hostPolicy: HostPolicy

  public init(addresses: [String], port: Int, hostPolicy: HostPolicy) {
    self.addresses = addresses
    self.port = port
    self.hostPolicy = hostPolicy
  }
}

/// The HTTP server in front of the engine: checks the Host header, answers
/// cloud-model requests itself (`CloudRouter`) and passes everything else through
/// to the engine.
public actor Gateway {
  private let engine: @Sendable () -> EngineEndpoint?
  private let cloudProviders = CloudProviders()
  private let cloudSettings = CloudSettingsBackendBox()
  private let logger: Logger
  private var listeners: [Task<Void, Never>] = []
  public private(set) var configuration: GatewayConfiguration?

  public init(engine: @escaping @Sendable () -> EngineEndpoint?) {
    self.engine = engine
    var logger = Logger(label: "localchat.gateway")
    logger.logLevel = .warning
    self.logger = logger
  }

  public var isRunning: Bool { !listeners.isEmpty }

  /// The cloud providers to route to (with keys and chosen models). Takes effect
  /// for the next request; no restart needed.
  public nonisolated func setCloudProviders(_ providers: [CloudProvider]) {
    cloudProviders.replace(providers)
  }

  /// Where the chat UI's Cloud settings read and write (`/localchat/cloud/...`).
  public nonisolated func setCloudSettingsBackend(_ backend: CloudSettingsBackend?) {
    cloudSettings.set(backend)
  }

  /// Binds every address in `configuration`, replacing any current listeners.
  /// Returns once all are accepting connections; throws (with nothing left
  /// running) if any address can't be bound, for example because the port is taken.
  public func start(_ configuration: GatewayConfiguration) async throws {
    await stop()
    let responder = GatewayResponder(
      hostPolicy: configuration.hostPolicy,
      proxy: EngineProxy(engine: engine),
      cloud: CloudRouter(
        providers: cloudProviders, catalog: .shared,
        access: CloudAccessPolicy(port: configuration.port), session: CloudRouter.streamingSession),
      settingsAPI: CloudSettingsAPI(backend: { [cloudSettings] in cloudSettings.backend }))

    var started: [Task<Void, Never>] = []
    do {
      for address in configuration.addresses {
        started.append(
          try await Self.listen(
            address: address, port: configuration.port, responder: responder, logger: logger))
      }
    } catch {
      for task in started { task.cancel() }
      for task in started { await task.value }
      throw error
    }
    listeners = started
    self.configuration = configuration
  }

  /// Stops all listeners and waits until their ports are released.
  public func stop() async {
    let running = listeners
    listeners = []
    configuration = nil
    for task in running { task.cancel() }
    for task in running { await task.value }
  }

  private static func listen(
    address: String, port: Int, responder: GatewayResponder, logger: Logger
  ) async throws -> Task<Void, Never> {
    let signal = StartSignal()
    let task = Task {
      let app = Application(
        responder: responder,
        configuration: ApplicationConfiguration(
          address: .hostname(address, port: port), serverName: nil),
        onServerRunning: { _ in signal.succeed() },
        logger: logger
      )
      do {
        // No signal handlers: this runs inside the app, which handles its own termination.
        try await app.runService(gracefulShutdownSignals: [])
        signal.fail(GatewayError.stoppedBeforeStarting)
      } catch {
        signal.fail(error)
      }
    }
    do {
      try await signal.wait()
    } catch {
      task.cancel()
      await task.value
      throw error
    }
    return task
  }
}

public enum GatewayError: Error {
  case stoppedBeforeStarting
}

/// Request context that remembers whether the client is on this Mac.
struct GatewayContext: RequestContext {
  var coreContext: CoreRequestContextStorage
  let clientIsLoopback: Bool

  init(source: ApplicationRequestContextSource) {
    self.coreContext = .init(source: source)
    let address = source.channel.remoteAddress?.ipAddress ?? ""
    self.clientIsLoopback =
      address == "::1" || address.hasPrefix("127.") || address.hasPrefix("::ffff:127.")
  }
}

struct GatewayResponder: HTTPResponder {
  typealias Context = GatewayContext

  let hostPolicy: HostPolicy
  let proxy: EngineProxy
  let cloud: CloudRouter
  let settingsAPI: CloudSettingsAPI

  /// Endpoints that name a model in their JSON body.
  static let modelBodyPaths: Set<String> = [
    "/v1/chat/completions", "/models/load", "/models/unload", "/v1/chat/completions/control",
    "/v1/messages", "/v1/responses", "/v1/completions", "/chat/completions", "/completions",
  ]

  func respond(to request: Request, context: Context) async throws -> Response {
    guard hostPolicy.allows(host: request.head.authority) else { return .forbiddenHost }
    let path = request.uri.path
    let cloudAllowed = cloud.access.allows(
      origin: request.headers[.origin], clientIsLoopback: context.clientIsLoopback)

    if path.hasPrefix(CloudSettingsAPI.prefix) {
      return cloudAllowed ? await settingsAPI.handle(request, path: path) : .cloudForbidden
    }

    switch (request.method, path) {
    case (.get, "/v1/models"), (.get, "/models"):
      guard cloudAllowed else { break }
      let cloudModels = await cloud.listedModels()
      guard !cloudModels.isEmpty else { break }
      let engine = await proxy.fetchJSON(request.head.path ?? path, headers: request.headers)
      return .json(CloudSynthesis.mergeModelList(engine: engine, cloud: cloudModels))

    case (.get, "/props"):
      guard let model = request.uri.queryParameters["model"].map(String.init), CloudModelID.isCloud(model) else {
        break
      }
      return cloudAllowed ? await cloud.props(modelID: model) : .cloudForbidden

    case (.post, _) where Self.modelBodyPaths.contains(path):
      let body: ByteBuffer
      do {
        body = try await request.body.collect(upTo: EngineProxy.maxRequestBody)
      } catch {
        return .jsonError(.contentTooLarge, type: "invalid_request_error", message: "Request body too large.")
      }
      guard let json = (try? JSONSerialization.jsonObject(with: Data(body.readableBytesView))) as? [String: Any],
        let model = json["model"] as? String, CloudModelID.isCloud(model)
      else { return await proxy.forward(request, body: body) }
      guard cloudAllowed else { return .cloudForbidden }

      switch path {
      case "/v1/chat/completions", "/chat/completions":
        return await cloud.chat(body: json, modelID: model)
      case "/models/load", "/models/unload":
        return cloud.resolve(model) == nil ? .unknownCloudModel(model) : .json(["success": true])
      default:
        return .cloudUnsupported(path)
      }

    default:
      break
    }
    return await proxy.forward(request)
  }
}

/// One-shot "the listener is up, or failed" signal that tolerates firing
/// before anyone waits.
final class StartSignal: @unchecked Sendable {
  private enum State {
    case pending(CheckedContinuation<Void, Error>?)
    case done(Result<Void, Error>)
  }

  private let lock = NSLock()
  private var state: State = .pending(nil)

  func succeed() { resolve(.success(())) }
  func fail(_ error: Error) { resolve(.failure(error)) }

  private func resolve(_ result: Result<Void, Error>) {
    lock.lock()
    guard case .pending(let continuation) = state else {
      lock.unlock()
      return
    }
    state = .done(result)
    lock.unlock()
    continuation?.resume(with: result)
  }

  func wait() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      lock.lock()
      switch state {
      case .pending:
        state = .pending(continuation)
        lock.unlock()
      case .done(let result):
        lock.unlock()
        continuation.resume(with: result)
      }
    }
  }
}
