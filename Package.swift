// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "lsfg-metal",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LSFGCore", targets: ["LSFGCore"]),
        .executable(name: "lsfg-metal", targets: ["lsfg-metal"]),
        // C API for the CrossOver hook; built for x86_64 (Rosetta) by hook/build.sh.
        .library(name: "LSFGBridge", type: .dynamic, targets: ["LSFGBridge"]),
    ],
    targets: [
        .target(name: "LSFGCore"),
        .target(name: "LSFGBridge", dependencies: ["LSFGCore"]),
        .executableTarget(name: "lsfg-metal", dependencies: ["LSFGCore"]),
        .testTarget(name: "LSFGCoreTests", dependencies: ["LSFGCore"]),
    ]
)
