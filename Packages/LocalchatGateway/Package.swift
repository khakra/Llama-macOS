// swift-tools-version:6.0
// FORK: localchat gateway (see docs/gateway.md in khakra/localchat).
import PackageDescription

let package = Package(
  name: "LocalchatGateway",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "LocalchatGateway", targets: ["LocalchatGateway"])
  ],
  dependencies: [
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.37.0"),
  ],
  targets: [
    .target(
      name: "LocalchatGateway",
      dependencies: [
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "MCP", package: "swift-sdk"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // AsyncHTTPClient is only the tests' HTTP client (it can set a Host header); the app doesn't link it.
    .testTarget(
      name: "LocalchatGatewayTests",
      dependencies: [
        "LocalchatGateway",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "MCP", package: "swift-sdk"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
