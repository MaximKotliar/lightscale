// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lightscale",
    platforms: [.macOS(.v15)],
    products: [
        // The setup app (bundled into "Lightscale.app" by scripts/build-app.sh).
        .executable(name: "Lightscale", targets: ["LSFGMetalApp"]),
    ],
    dependencies: [
        // Submodules (git submodule update --init): pinned commits of the two engines.
        .package(path: "vendor/lsfg-metal"),
    ],
    targets: [
        .executableTarget(name: "LSFGMetalApp", dependencies: [.product(name: "LSFGCore", package: "lsfg-metal")]),
        .testTarget(name: "LSFGMetalAppTests", dependencies: [
            "LSFGMetalApp", .product(name: "LSFGCore", package: "lsfg-metal"),
        ]),
    ]
)
