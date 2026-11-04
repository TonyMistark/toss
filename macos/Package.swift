// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Toss",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Toss",
            path: "Sources/Toss"
        ),
        .testTarget(
            name: "TossTests",
            dependencies: ["Toss"],
            path: "Tests/TossTests"
        )
    ]
)
