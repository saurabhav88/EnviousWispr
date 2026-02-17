// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VibeWhisper",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.12.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.1.0"),
        // KeyboardShortcuts deferred to M2 — requires full Xcode for #Preview macros
        // .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "VibeWhisper",
            dependencies: [
                "WhisperKit",
                "FluidAudio",
                // "KeyboardShortcuts", // M2: add back when full Xcode available
            ],
            path: "Sources/VibeWhisper",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "VibeWhisperTests",
            dependencies: ["VibeWhisper"],
            path: "Tests/VibeWhisperTests"
        ),
    ]
)
