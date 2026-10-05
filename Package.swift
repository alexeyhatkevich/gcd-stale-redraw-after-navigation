// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StaleRedraw",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "StaleRedraw", targets: ["StaleRedraw"]),
    ],
    targets: [
        .target(name: "StaleRedraw"),
        .testTarget(name: "StaleRedrawTests", dependencies: ["StaleRedraw"]),
    ]
)
