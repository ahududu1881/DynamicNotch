// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DynamicNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DynamicNotch",
            path: "Sources/DynamicNotch"
        ),
        .testTarget(
            name: "DynamicNotchTests",
            dependencies: ["DynamicNotch"],
            path: "Tests/DynamicNotchTests"
        ),
    ]
)
