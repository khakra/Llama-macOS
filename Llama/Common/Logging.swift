import Foundation

enum Logging {
  // FORK: our bundle ID (app.localchat), set in project.pbxproj.
  #if DEBUG
    static let subsystem = "app.localchat.dev"
  #else
    static let subsystem = "app.localchat"
  #endif
}
