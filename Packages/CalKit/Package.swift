// swift-tools-version: 6.0
import PackageDescription

// CalKit is deliberately platform-agnostic and dependency-free: no SwiftUI, no
// SwiftData, no network. That is what lets `swift test` run the whole suite
// natively in ~2s with no simulator, which is the inner loop in
// ARCHITECTURE.md §11.2. Keep it that way — if something here needs UIKit or a
// URLSession, it belongs in CalDesign or CalData instead.
let package = Package(
    name: "CalKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CalKit", targets: ["CalKit"])
    ],
    targets: [
        .target(name: "CalKit"),
        .testTarget(name: "CalKitTests", dependencies: ["CalKit"]),
    ]
)
