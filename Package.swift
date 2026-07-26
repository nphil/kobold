// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kobold",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // Pure-Foundation core: transport contracts, ELM327 protocol, decoding,
        // vehicle profiles. No CoreBluetooth, no SwiftUI — builds and tests on
        // any platform, including Linux CI.
        .library(name: "KoboldCore", targets: ["KoboldCore"]),
    ],
    targets: [
        .target(
            name: "KoboldCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "KoboldCoreTests",
            dependencies: ["KoboldCore"]
        ),
    ]
)
