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

#if os(macOS)
targets.append(
    .executableTarget(
        name: "LiteCap",
        dependencies: ["LiteCapCore"],
        path: "Sources/LiteCap",
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
#endif

let package = Package(
    name: "LiteCap",
    platforms: [.macOS(.v15)],
    targets: targets
)
