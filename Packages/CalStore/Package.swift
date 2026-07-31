// swift-tools-version: 6.0
import PackageDescription

// The purchase seam. StoreKit lives *only* behind `StoreKitEntitlementProvider`,
// so everything that decides what a person can see is testable without an App
// Store, a sandbox account, or a simulator (ARCHITECTURE.md §11.2).
//
// macOS is here for the same reason as the other packages: `swift test` runs the
// suite natively in seconds. The StoreKit-backed provider is iOS-only and is
// compiled out elsewhere, which is exactly why the seam is worth having.
let package = Package(
    name: "CalStore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CalStore", targets: ["CalStore"])
    ],
    dependencies: [
        .package(path: "../CalKit")
    ],
    targets: [
        .target(name: "CalStore", dependencies: ["CalKit"]),
        .testTarget(name: "CalStoreTests", dependencies: ["CalStore"]),
    ]
)
