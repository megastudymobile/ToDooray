// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MegaMind",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MegaMindApp", targets: ["MegaMindApp"]),
    ],
    targets: [
        .target(name: "DooraySync"),
        .target(name: "MegaMindApp", dependencies: ["DooraySync"]),
        .testTarget(name: "DooraySyncTests", dependencies: ["DooraySync"]),
        .testTarget(name: "MegaMindAppTests", dependencies: ["MegaMindApp", "DooraySync"]),
    ]
)
