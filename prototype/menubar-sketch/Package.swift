// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sketch",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Sketch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
