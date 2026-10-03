// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BonedustCore",
    platforms: [
        // macOS is listed so `swift test` runs the simulation suites on the host
        // without booting a simulator. It also means the core *cannot* import
        // SpriteKit or UIKit, which keeps the purity rule from §2 enforced by the
        // compiler rather than by discipline.
        .iOS(.v17), .macOS(.v14),
    ],
    products: [
        .library(name: "BonedustCore", targets: ["BonedustCore"]),
    ],
    targets: [
        .target(
            name: "BonedustCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "bonedust-tool",
            dependencies: ["BonedustCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BonedustCoreTests",
            dependencies: ["BonedustCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
