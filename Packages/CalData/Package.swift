// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalData",
    // macOS 15, unlike the other packages' 14: SwiftData's `#Unique` macro needs it.
    // The macOS platform exists purely so `swift test` runs natively with no
    // simulator, so raising it costs nothing — iOS 18 already has `#Unique`.
    platforms: [.iOS(.v18), .macOS(.v15)],
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
