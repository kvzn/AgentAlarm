// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentAlarmCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentAlarmCore", targets: ["AgentAlarmCore"]),
    ],
    targets: [
        .target(
            name: "AgentAlarmCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "AgentAlarmCoreTests",
            dependencies: ["AgentAlarmCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
