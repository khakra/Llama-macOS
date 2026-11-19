// FORK: localchat gateway.
import Foundation

/// Which `Host` values the gateway answers. When it only listens on loopback,
/// anything else is a DNS-rebinding attempt: a web page that resolved its own
/// name to 127.0.0.1 to reach us from the user's browser.
public struct HostPolicy: Sendable, Equatable {
  public var loopbackOnly: Bool

  public init(loopbackOnly: Bool) {
    self.loopbackOnly = loopbackOnly
  }

  static let loopbackNames: Set<String> = ["localhost", "127.0.0.1", "::1"]

  /// A missing Host is allowed: browsers always send one, so its absence means
  /// a local tool, not a rebinding page.
  public func allows(host: String?) -> Bool {
    guard loopbackOnly, let host else { return true }
    guard let name = Self.hostname(fromAuthority: host) else { return false }
    return Self.loopbackNames.contains(name) || name.hasSuffix(".localhost")
  }

  /// `[::1]:9931` -> `::1`, `localhost:9931` -> `localhost`, lowercased.
  static func hostname(fromAuthority authority: String) -> String? {
    var value = authority.trimmingCharacters(in: .whitespaces).lowercased()
    if value.hasSuffix(".") { value.removeLast() }
    guard !value.isEmpty else { return nil }
    if value.hasPrefix("[") {
      guard let close = value.firstIndex(of: "]") else { return nil }
      return String(value[value.index(after: value.startIndex)..<close])
    }
    if let colon = value.lastIndex(of: ":") {
      return String(value[..<colon])
    }
    return value
  }
}
