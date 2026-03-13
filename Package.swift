// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EnviousWispr",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.12.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        .package(url: "https://github.com/TelemetryDeck/SwiftSDK.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "EnviousWisprCore",
            path: "Sources/EnviousWisprCore"
        ),
        .executableTarget(
            name: "EnviousWispr",
            dependencies: [
                "EnviousWisprCore",
                "WhisperKit",
                "FluidAudio",
                "Sparkle",
                .product(name: "TelemetryDeck", package: "SwiftSDK"),
            ],
            path: "Sources/EnviousWispr",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "EnviousWisprTests",
            dependencies: ["EnviousWispr"],
            path: "Tests/EnviousWisprTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
