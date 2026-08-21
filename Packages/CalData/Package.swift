// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalData",
    // macOS 15 so `swift test` can run natively with SwiftData; iOS 17 matches
    // the app deployment target.
    platforms: [.iOS(.v17), .macOS(.v15)],
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
