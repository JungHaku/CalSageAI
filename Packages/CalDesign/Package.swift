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
        .target(
            name: "CalDesign",
            dependencies: ["CalKit"],
            // The Cal artwork. `.process` so the catalogue is compiled by
            // `actool` rather than copied — a copied `.xcassets` is a folder in
            // the bundle, and `Image(_:bundle:)` resolves names only against a
            // compiled one.
            resources: [.process("Resources")]
        ),
        .testTarget(name: "CalDesignTests", dependencies: ["CalDesign"]),
    ]
)
