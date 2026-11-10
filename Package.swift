// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MusicSync",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MusicSyncCore"),
        .executableTarget(name: "MusicSync", dependencies: ["MusicSyncCore"]),
        .testTarget(name: "MusicSyncCoreTests", dependencies: ["MusicSyncCore"]),
    ]
)
