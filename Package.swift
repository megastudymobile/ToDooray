// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ToDooray",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ToDoorayApp", targets: ["ToDoorayApp"]),
    ],
    targets: [
        .target(name: "DooraySync"),
        .target(name: "ToDoorayApp", dependencies: ["DooraySync"]),
        .testTarget(name: "DooraySyncTests", dependencies: ["DooraySync"]),
        .testTarget(name: "ToDoorayAppTests", dependencies: ["ToDoorayApp", "DooraySync"]),
    ]
)
