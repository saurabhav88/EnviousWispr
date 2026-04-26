// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "EnviousWispr",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    // Exposed so the multilingual polish-quality harness (a separate
    // SwiftPM package at scripts/multilingual-eval/polisher-runner) can
    // depend on the real planner + connectors via a path-based package
    // dependency. Purely additive — no production code imports these.
    .library(name: "EnviousWisprCore", targets: ["EnviousWisprCore"]),
    .library(name: "EnviousWisprLLM", targets: ["EnviousWisprLLM"]),
  ],
  dependencies: [
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.12.0"),
    .package(url: "https://github.com/saurabhav88/FluidAudio.git", revision: "46e96f4"),
    .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0"),
    .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.8.0"),
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
      dependencies: [
        "EnviousWisprCore",
        .product(name: "PostHog", package: "posthog-ios"),
        .product(name: "Sentry", package: "sentry-cocoa"),
      ],
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
      name: "EnviousWisprAudioService",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprAudio",
      ],
      path: "Sources/EnviousWisprAudioService",
      exclude: ["Resources"]
    ),
    .executableTarget(
      name: "EnviousWisprASRService",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprASR",
        "EnviousWisprAudio",
        "WhisperKit",
        "FluidAudio",
      ],
      path: "Sources/EnviousWisprASRService",
      exclude: ["Resources"]
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
      ],
      path: "Sources/EnviousWispr",
      exclude: ["Resources"]
    ),
    .testTarget(
      name: "EnviousWisprTests",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprPostProcessing",
        "EnviousWisprLLM",
        "EnviousWisprPipeline",
        "EnviousWisprStorage",
        "EnviousWisprAudio",
        "EnviousWispr",
      ],
      path: "Tests/EnviousWisprTests"
    ),
    .testTarget(
      name: "EnviousWisprASRTests",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprASR",
      ],
      path: "Tests/EnviousWisprASRTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
