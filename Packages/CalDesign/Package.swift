// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalDesign",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CalDesign", targets: ["CalDesign"])
    ],
    dependencies: [
        .package(path: "../CalKit")
    ],
    targets: [
        .target(
            name: "CalDesign",
            dependencies: ["CalKit"]
            // Character art is drawn in CalAvatar — no bundled mascot images.
        ),
        .testTarget(name: "CalDesignTests", dependencies: ["CalDesign"]),
    ]
)
