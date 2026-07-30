// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalDesign",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CalDesign", targets: ["CalDesign"])
    ],
    dependencies: [
        .package(path: "../CalKit")
    ],
    targets: [
        .target(name: "CalDesign", dependencies: ["CalKit"]),
        .testTarget(name: "CalDesignTests", dependencies: ["CalDesign"]),
    ]
)
