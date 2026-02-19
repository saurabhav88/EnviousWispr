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
    ],
    targets: [
        .executableTarget(
            name: "EnviousWispr",
            dependencies: [
                "WhisperKit",
                "FluidAudio",
                "Sparkle",
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
