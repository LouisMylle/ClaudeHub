// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeHub",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeHub",
            dependencies: ["SwiftTerm"],
            path: "Sources/ClaudeHub",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
