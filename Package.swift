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
        // The setup app (bundled into "Lightscale.app" by scripts/build-app.sh).
        .executable(name: "Lightscale", targets: ["LSFGMetalApp"]),
    ],
    targets: [
        .target(name: "LSFGCore"),
        .target(name: "LSFGBridge", dependencies: ["LSFGCore"]),
        .executableTarget(name: "LSFGMetalApp", dependencies: ["LSFGCore"]),
        .executableTarget(name: "lsfg-metal", dependencies: ["LSFGCore"]),
        .testTarget(name: "LSFGCoreTests", dependencies: ["LSFGCore"]),
        .testTarget(name: "LSFGMetalAppTests", dependencies: ["LSFGMetalApp"]),
    ]
)
