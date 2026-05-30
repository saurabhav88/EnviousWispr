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
    // Exposed for the alias-suggestion eval harness at
    // scripts/eval/alias_runner. Purely additive — no production code
    // imports change. (#637)
    .library(name: "EnviousWisprPostProcessing", targets: ["EnviousWisprPostProcessing"]),
  ],
  dependencies: [
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
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
      path: "Sources/EnviousWisprPostProcessing",
      resources: [.process("Resources")]
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
        .product(name: "WhisperKit", package: "argmax-oss-swift"),
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
        // R2 (#360): WhisperKit dependency dropped — Pipeline no longer
        // references WhisperKit-typed values directly. The reach goes
        // through `EnviousWisprASR`'s package-access seams
        // (`makeIncrementalSession`, `observeLID`).
      ],
      path: "Sources/EnviousWisprPipeline"
    ),
    // #919: the app-shell layer (homes + views + composition root) lives in
    // this library so the unit-test target can link it WITHOUT launching the
    // app. The launchable `EnviousWispr` target is a thin shell over it.
    .target(
      name: "EnviousWisprAppKit",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprStorage",
        "EnviousWisprPostProcessing",
        "EnviousWisprAudio",
        "EnviousWisprServices",
        "EnviousWisprASR",
        "EnviousWisprLLM",
        "EnviousWisprPipeline",
        .product(name: "WhisperKit", package: "argmax-oss-swift"),
        "FluidAudio",
        "Sparkle",
      ],
      path: "Sources/EnviousWisprAppKit"
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
        .product(name: "WhisperKit", package: "argmax-oss-swift"),
        "FluidAudio",
      ],
      path: "Sources/EnviousWisprASRService",
      exclude: ["Resources"]
    ),
    // #919: thin launchable shell. Owns @main + the AppDelegate adaptor +
    // app identity/Resources; delegates ALL construction + lifecycle to
    // `WisprBootstrapper` in EnviousWisprAppKit. Depends ONLY on the kit.
    .executableTarget(
      name: "EnviousWispr",
      dependencies: [
        "EnviousWisprAppKit"
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
        // #919: link the app-shell code from the library, NOT the app target,
        // so `swift test` / `xcodebuild test` never launch the app.
        "EnviousWisprAppKit",
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
