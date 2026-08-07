// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "claude-usage-menubar",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(
            name: "usage-cli",
            dependencies: ["UsageCore"]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
