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
        // CoreBluetooth transport. Apple-only in practice: the sources are
        // guarded so the target still compiles to an empty module elsewhere,
        // which keeps `swift build` working on Linux CI.
        .library(name: "KoboldBLE", targets: ["KoboldBLE"]),
        // Diagnostics. Pure Foundation so it can be used from every layer,
        // including code that also builds on Linux.
        .library(name: "KoboldLog", targets: ["KoboldLog"]),
    ],
    targets: [
        .target(
            name: "KoboldCore",
            // Diagnostics only. KoboldLog is pure Foundation, so this keeps
            // KoboldCore buildable everywhere, Linux CI included.
            dependencies: ["KoboldLog"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "KoboldBLE",
            dependencies: ["KoboldCore", "KoboldLog"]
        ),
        .target(
            name: "KoboldLog"
        ),
        .testTarget(
            name: "KoboldCoreTests",
            dependencies: ["KoboldCore", "KoboldLog"]
        ),
    ]
)
