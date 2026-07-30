// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalContent",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CalContent", targets: ["CalContent"])
    ],
    dependencies: [
        .package(path: "../CalKit")
    ],
    targets: [
        .target(
            name: "CalContent",
            dependencies: ["CalKit"],
            // Bundled so a fresh install works before its first sync and in
            // airplane mode (ARCHITECTURE.md §7).
            resources: [.process("Resources")]
        ),
        .testTarget(name: "CalContentTests", dependencies: ["CalContent"]),
    ]
)
