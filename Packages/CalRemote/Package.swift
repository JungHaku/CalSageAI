// swift-tools-version: 6.0
import PackageDescription

// The backend. This is the ONLY package that knows Supabase exists, and the only
// one with an external dependency at all — everything else in the project is
// local. Confining it here means `swift test` on CalKit still runs in two seconds
// with nothing to resolve, and it keeps the blast radius of an SDK upgrade to one
// target (ARCHITECTURE.md §2, §15).
//
// Note what comes along: supabase-swift resolves seven packages and links, among
// others, XCTestDynamicOverlay and IssueReporting into the shipping binary. That
// is the SDK's choice, not ours, but it is the cost of this line.
let package = Package(
    name: "CalRemote",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "CalRemote", targets: ["CalRemote"])
    ],
    dependencies: [
        .package(path: "../CalKit"),
        .package(path: "../CalData"),
        .package(path: "../CalContent"),
        // Pinned exactly. A sync layer is the wrong place to discover that a minor
        // release changed an encoding default.
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.54.1"),
    ],
    targets: [
        .target(
            name: "CalRemote",
            dependencies: [
                "CalKit", "CalData", "CalContent",
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(name: "CalRemoteTests", dependencies: ["CalRemote"]),
    ]
)
