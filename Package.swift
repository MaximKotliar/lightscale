// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lsfg-metal",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LSFGCore", targets: ["LSFGCore"]),
        .executable(name: "lsfg-metal", targets: ["lsfg-metal"]),
    ],
    targets: [
        .target(name: "LSFGCore"),
        .executableTarget(name: "lsfg-metal", dependencies: ["LSFGCore"]),
        .testTarget(name: "LSFGCoreTests", dependencies: ["LSFGCore"]),
    ]
)
