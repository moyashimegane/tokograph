// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tokograph",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "TokographCore"),
        .executableTarget(name: "tokograph", dependencies: ["TokographCore"]),
        .testTarget(name: "TokographCoreTests", dependencies: ["TokographCore"]),
    ]
)
