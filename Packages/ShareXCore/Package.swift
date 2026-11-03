// swift-tools-version: 6.0
// Platform-free core. Builds and tests on Linux and macOS.
// The macOS app target lives in project.yml (XcodeGen) and depends on this package.
import PackageDescription

let package = Package(
    name: "ShareXCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ShareXCore", targets: ["ShareXCore"])],
    targets: [
        .target(name: "ShareXCore"),
        .testTarget(name: "ShareXCoreTests", dependencies: ["ShareXCore"]),
    ]
)
