// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalData",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CalData", targets: ["CalData"])
    ],
    dependencies: [
        .package(path: "../CalKit")
    ],
    targets: [
        .target(name: "CalData", dependencies: ["CalKit"]),
        .testTarget(name: "CalDataTests", dependencies: ["CalData"]),
    ]
)
