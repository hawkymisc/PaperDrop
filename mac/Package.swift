// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PaperDrop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PaperDrop", targets: ["PaperDrop"]),
        .executable(name: "paperdrop-cli", targets: ["paperdrop-cli"]),
        .library(name: "PaperKit", targets: ["PaperKit"]),
    ],
    targets: [
        .target(name: "PaperKit"),
        .executableTarget(name: "PaperDrop", dependencies: ["PaperKit"]),
        .executableTarget(name: "paperdrop-cli", dependencies: ["PaperKit"]),
        .testTarget(name: "PaperKitTests", dependencies: ["PaperKit"]),
    ]
)
