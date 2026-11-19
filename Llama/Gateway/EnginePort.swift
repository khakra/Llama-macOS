import Darwin
import Foundation

// FORK: localchat gateway (docs/gateway.md in khakra/localchat).
/// The engine's internal port while the gateway holds the user-facing one.
enum EnginePort {
  /// Fixed rather than random, so an engine orphaned by a crash is found and
  /// reclaimed on the next launch, the same way the user port was before the gateway.
  static let preferred = 19931

  private static let lock = NSLock()
  nonisolated(unsafe) private static var value = preferred

  /// The port the engine was last launched on. Read by the gateway per request.
  static var current: Int { lock.withLock { value } }

  /// Chooses the engine port for a launch: frees `preferred` from an orphaned
  /// `llama` if one holds it, else falls back to any free port.
  /// Blocks (runs `lsof`/`ps`), so call it off the main actor.
  static func prepareForLaunch(userPort: Int) -> Int {
    var port = preferred == userPort ? preferred + 1 : preferred
    _ = LlamaServer.reclaimPort(port)
    if !canListen(on: port), let free = freePort() {
      port = free
    }
    lock.withLock { value = port }
    return port
  }

  /// Whether a listener could bind `port` right now. Unlike
  /// `LlamaServer.isPortAvailable`, this sets SO_REUSEADDR, as the engine does:
  /// the gateway's closed connections to the previous engine linger in
  /// TIME_WAIT for a while and must not count as "taken". A live listener still does.
  static func canListen(on port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return true }
    defer { close(fd) }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  /// A loopback port nothing is listening on right now.
  static func freePort() -> Int? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
      }
    }
    return bound ? Int(UInt16(bigEndian: addr.sin_port)) : nil
  }
}
