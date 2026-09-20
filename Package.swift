// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "coding-agent-usage-tracker",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(
            name: "usage-cli",
            dependencies: ["UsageCore"]
        ),
        .executableTarget(
            name: "AgentUsage",
            dependencies: ["UsageCore"]
        ),
        .executableTarget(
            name: "usaged",
            dependencies: ["UsageCore"]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
