// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DotfileSyncKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "IPC", targets: ["IPC"]),
        .library(name: "Agent", targets: ["Agent"]),
        .library(name: "XPCTransport", targets: ["XPCTransport"]),
        .library(name: "AgentRegistration", targets: ["AgentRegistration"]),
        .executable(name: "dotfilesyncd", targets: ["dotfilesyncd"]),
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
        .target(
            name: "XPCTransport",
            dependencies: ["Core", "IPC", "Agent"]
        ),
        .testTarget(
            name: "XPCTransportTests",
            dependencies: ["Core", "IPC", "Agent", "XPCTransport"]
        ),
        .executableTarget(
            name: "dotfilesyncd",
            dependencies: ["Core", "IPC", "Agent", "XPCTransport"]
        ),
        .testTarget(
            name: "DaemonBinaryTests",
            // Depends on the executable only so `swift build --build-tests` builds it first;
            // the tests spawn the built binary and never import it.
            dependencies: ["Core", "IPC", "dotfilesyncd"]
        ),
        .target(
            name: "AgentRegistration",
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .testTarget(
            name: "AgentRegistrationTests",
            dependencies: ["AgentRegistration"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
