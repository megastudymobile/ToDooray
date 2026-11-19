// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MegaMind",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DooraySync"),
        .testTarget(name: "DooraySyncTests", dependencies: ["DooraySync"]),
    ]
)
