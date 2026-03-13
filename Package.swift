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
        .target(
            name: "EnviousWisprStorage",
            dependencies: ["EnviousWisprCore"],
            path: "Sources/EnviousWisprStorage"
        ),
        .target(
            name: "EnviousWisprPostProcessing",
            dependencies: ["EnviousWisprCore"],
            path: "Sources/EnviousWisprPostProcessing"
        ),
        .target(
            name: "EnviousWisprAudio",
            dependencies: [
                "EnviousWisprCore",
                "FluidAudio",
            ],
            path: "Sources/EnviousWisprAudio"
        ),
        .target(
            name: "EnviousWisprServices",
            dependencies: ["EnviousWisprCore"],
            path: "Sources/EnviousWisprServices"
        ),
        .target(
            name: "EnviousWisprASR",
            dependencies: [
                "EnviousWisprCore",
                "EnviousWisprAudio",
                "WhisperKit",
                "FluidAudio",
            ],
            path: "Sources/EnviousWisprASR"
        ),
        .target(
            name: "EnviousWisprLLM",
            dependencies: ["EnviousWisprCore"],
            path: "Sources/EnviousWisprLLM"
        ),
        .target(
            name: "EnviousWisprPipeline",
            dependencies: [
                "EnviousWisprCore",
                "EnviousWisprASR",
                "EnviousWisprAudio",
                "EnviousWisprLLM",
                "EnviousWisprPostProcessing",
                "EnviousWisprServices",
                "EnviousWisprStorage",
                "WhisperKit",
            ],
            path: "Sources/EnviousWisprPipeline"
        ),
        .executableTarget(
            name: "EnviousWispr",
            dependencies: [
                "EnviousWisprCore",
                "EnviousWisprStorage",
                "EnviousWisprPostProcessing",
                "EnviousWisprAudio",
                "EnviousWisprServices",
                "EnviousWisprASR",
                "EnviousWisprLLM",
                "EnviousWisprPipeline",
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
            dependencies: ["EnviousWispr", "EnviousWisprCore"],
            path: "Tests/EnviousWisprTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
