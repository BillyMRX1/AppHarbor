// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AppHarbor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppHarborCore", targets: ["AppHarborCore"]),
        .library(name: "AppHarborMCPBridge", targets: ["AppHarborMCPBridge"]),
        .executable(name: "AppHarborMCP", targets: ["AppHarborMCP"]),
        .executable(name: "AppHarbor", targets: ["AppHarbor"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(name: "AppHarborCore", path: "Sources/AppHarborCore"),
        .target(name: "AppHarborMCPBridge", dependencies: ["AppHarborCore"], path: "Sources/AppHarborMCPBridge"),
        .executableTarget(name: "AppHarborMCP", dependencies: ["AppHarborMCPBridge", .product(name: "MCP", package: "swift-sdk")], path: "Sources/AppHarborMCP"),
        .executableTarget(name: "AppHarbor", dependencies: ["AppHarborCore", "AppHarborMCPBridge"], path: "Sources/AppHarbor"),
        .testTarget(name: "AppHarborCoreTests", dependencies: ["AppHarborCore"], path: "Tests/AppHarborCoreTests"),
        .testTarget(name: "AppHarborMCPBridgeTests", dependencies: ["AppHarborMCPBridge", "AppHarborCore"], path: "Tests/AppHarborMCPBridgeTests"),
        .testTarget(name: "AppHarborMCPTests", dependencies: ["AppHarborMCP", "AppHarborMCPBridge", .product(name: "MCP", package: "swift-sdk")], path: "Tests/AppHarborMCPTests"),
        .testTarget(name: "AppHarborAppTests", dependencies: ["AppHarbor", "AppHarborCore", "AppHarborMCPBridge"], path: "Tests/AppHarborAppTests")
    ],
    swiftLanguageModes: [.v5]
)
