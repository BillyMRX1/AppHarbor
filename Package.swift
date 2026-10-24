// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppHarbor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppHarborCore", targets: ["AppHarborCore"]),
        .executable(name: "AppHarbor", targets: ["AppHarbor"])
    ],
    targets: [
        .target(name: "AppHarborCore", path: "Sources/AppHarborCore"),
        .executableTarget(name: "AppHarbor", dependencies: ["AppHarborCore"], path: "Sources/AppHarbor"),
        .testTarget(name: "AppHarborCoreTests", dependencies: ["AppHarborCore"], path: "Tests/AppHarborCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
