// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalContent",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CalContent", targets: ["CalContent"])
    ],
    targets: [
        .target(
            name: "CalContent",
            // Bundled so a fresh install works before its first sync and in
            // airplane mode (ARCHITECTURE.md §7).
            resources: [.process("Resources")]
        ),
        .testTarget(name: "CalContentTests", dependencies: ["CalContent"]),
    ]
)
