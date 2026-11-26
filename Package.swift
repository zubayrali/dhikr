// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dhikr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DhikrCore", targets: ["DhikrCore"]),
        .executable(name: "dhikr", targets: ["DhikrApp"])
    ],
    targets: [
        .target(name: "DhikrCore"),
        .executableTarget(
            name: "DhikrApp",
            dependencies: ["DhikrCore"]
        ),
        .testTarget(name: "DhikrCoreTests", dependencies: ["DhikrCore"])
    ]
)
