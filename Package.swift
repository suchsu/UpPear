// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UpPear",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UpPearCore", targets: ["UpPearCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.8.0")
    ],
    targets: [
        .target(name: "UpPearCore", dependencies: [.product(name: "Sparkle", package: "Sparkle")], path: "UpPear/Core")
    ],
    swiftLanguageModes: [.v6]
)
