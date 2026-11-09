// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgentDeck",
            path: "Sources/AgentDeck",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Fixture tests for the undocumented provider formats AgentDeck reads.
        .testTarget(
            name: "AgentDeckTests",
            dependencies: ["AgentDeck"],
            path: "Tests/AgentDeckTests",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ],
    swiftLanguageModes: [.v5]
)
