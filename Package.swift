// swift-tools-version:6.0
import PackageDescription

var targets: [Target] = [
    // Platform-independent pieces (RTMP, FLV, AMF0, Matroska muxer, audio FIFO). Also builds on Linux.
    .target(
        name: "LiteCapCore",
        path: "Sources/LiteCapCore",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "LiteCapCoreTests",
        dependencies: ["LiteCapCore"],
        path: "Tests/LiteCapCoreTests",
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
]

var dependencies: [Package.Dependency] = []

#if os(macOS)
// Sparkle: the standard macOS auto-updater (pinned; prebuilt, signed framework).
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.4"))
targets.append(
    .executableTarget(
        name: "LiteCap",
        dependencies: ["LiteCapCore", .product(name: "Sparkle", package: "Sparkle")],
        path: "Sources/LiteCap",
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
#endif

let package = Package(
    name: "LiteCap",
    platforms: [.macOS(.v15)],
    dependencies: dependencies,
    targets: targets
)
