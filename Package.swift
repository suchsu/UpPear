// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UpPear",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "UpPearCore", targets: ["UpPearCore"]),
        .executable(name: "UpPearDiagnostics", targets: ["UpPearDiagnostics"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.8.0")
    ],
    targets: [
        .target(name: "UpPearCore", dependencies: [.product(name: "Sparkle", package: "Sparkle")], path: "UpPear/Core"),
        .executableTarget(name: "UpPearDiagnostics", dependencies: ["UpPearCore"], path: "Tools/Diagnostics"),
        .testTarget(name: "UpPearCoreTests", dependencies: ["UpPearCore"], path: "Tests/UpPearCoreTests")
    ],
    swiftLanguageModes: [.v6]
)
