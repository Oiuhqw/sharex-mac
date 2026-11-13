// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShareXAgent",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ShareXAgent", targets: ["ShareXAgent"])],
    targets: [
        .target(name: "ShareXAgent"),
        .executableTarget(name: "ShareXAgentTestHost", dependencies: ["ShareXAgent"], path: "Tests/ShareXAgentTestHost"),
        .testTarget(name: "ShareXAgentTests", dependencies: ["ShareXAgent", "ShareXAgentTestHost"])
    ]
)
