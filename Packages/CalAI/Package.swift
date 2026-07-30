// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalAI",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CalAI", targets: ["CalAI"])
    ],
    dependencies: [
        .package(path: "../CalKit")
    ],
    targets: [
        .target(name: "CalAI", dependencies: ["CalKit"]),
        .testTarget(name: "CalAITests", dependencies: ["CalAI"]),
    ]
)
