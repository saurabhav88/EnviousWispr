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
    // Exposed for the tail-finalization eval harness at scripts/eval/tail_runner,
    // which drives the shipped WhisperKitStreamingSession through the benchmark-only
    // TailBenchmarkHarness facade. Purely additive — no production code imports
    // change. (#1276 PR-2)
    .library(name: "EnviousWisprASR", targets: ["EnviousWisprASR"]),
  ],
  dependencies: [
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
    .package(url: "https://github.com/saurabhav88/FluidAudio.git", revision: "e7948e1ac3e4eb0254201d19bb8496a4398c8476"),
    .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0"),
    .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.8.0"),
  ],
  targets: [
    .target(
      name: "EnviousWisprCore",
      path: "Sources/EnviousWisprCore"
    ),
    // Sentry-only privacy + crash-reporting leaf (#1174): the single home for
    // the event sanitizer + the helper Sentry bootstrap shared by the app (via
    // Services) AND both XPC helpers. Keeps the redactor one source of truth and
    // contains the Sentry SDK to exactly the modules that need it.
    .target(
      name: "EnviousWisprObservabilityCore",
      dependencies: [
        .product(name: "Sentry", package: "sentry-cocoa")
      ],
      path: "Sources/EnviousWisprObservabilityCore"
    ),
    .target(
      name: "EnviousWisprStorage",
      dependencies: ["EnviousWisprCore"],
      path: "Sources/EnviousWisprStorage"
    ),
    // #1348 Phase 2: the owned model-delivery layer (manifest-pinned fetch,
    // verification, admission). Leaf module: Core only — never imports
    // ASR/LLM/Pipeline (D4 placement). Backend adapters consume it downward.
    .target(
      name: "EnviousWisprModelDelivery",
      dependencies: ["EnviousWisprCore"],
      path: "Sources/EnviousWisprModelDelivery"
    ),
    .target(
      name: "EnviousWisprPostProcessing",
      dependencies: ["EnviousWisprCore"],
      path: "Sources/EnviousWisprPostProcessing",
      resources: [.process("Resources")]
    ),
    // Leaf module (Core only) wrapping the Contacts framework behind a narrow
    // read-only protocol for the Import-from-Contacts feature (#636). Consumed
    // by EnviousWisprAppKit; no .library product (internal-only).
    .target(
      name: "EnviousWisprContacts",
      dependencies: ["EnviousWisprCore"],
      path: "Sources/EnviousWisprContacts"
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
        "EnviousWisprObservabilityCore",
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
      dependencies: [
        "EnviousWisprCore",
        // #832/#913 PR8: public Argmax tokenizer surface for the output-safety
        // classifier pair-encoder seam (AutoTokenizerWrapper / TokenizerWrapper).
        .product(name: "ArgmaxOSS", package: "argmax-oss-swift"),
      ],
      path: "Sources/EnviousWisprLLM"
    ),
    .target(
      name: "EnviousWisprPipeline",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprASR",
        "EnviousWisprAudio",
        "EnviousWisprLLM",
        "EnviousWisprModelDelivery",
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
        "EnviousWisprModelDelivery",
        "EnviousWisprPostProcessing",
        "EnviousWisprAudio",
        "EnviousWisprServices",
        "EnviousWisprASR",
        "EnviousWisprLLM",
        "EnviousWisprPipeline",
        "EnviousWisprContacts",
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
        "EnviousWisprObservabilityCore",
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
        "EnviousWisprObservabilityCore",
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
        "EnviousWisprObservabilityCore",
        "EnviousWisprModelDelivery",
        "EnviousWisprPostProcessing",
        "EnviousWisprLLM",
        "EnviousWisprPipeline",
        "EnviousWisprStorage",
        "EnviousWisprAudio",
        // #919: link the app-shell code from the library, NOT the app target,
        // so `swift test` / `xcodebuild test` never launch the app.
        "EnviousWisprAppKit",
        "EnviousWisprContacts",
      ],
      path: "Tests/EnviousWisprTests"
    ),
    .testTarget(
      name: "EnviousWisprASRTests",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprASR",
        "FluidAudio",
      ],
      path: "Tests/EnviousWisprASRTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
