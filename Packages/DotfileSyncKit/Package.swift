// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DotfileSyncKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "IPC", targets: ["IPC"]),
        .library(name: "Agent", targets: ["Agent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "Core",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"]
        ),
        .target(
            name: "IPC",
            dependencies: ["Core"]
        ),
        .target(
            name: "Agent",
            dependencies: ["Core", "IPC"]
        ),
        .testTarget(
            name: "IPCTests",
            dependencies: ["Core", "IPC"]
        ),
        .testTarget(
            name: "AgentTests",
            dependencies: ["Core", "IPC", "Agent"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
