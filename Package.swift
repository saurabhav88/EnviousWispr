// swift-tools-version: 6.2

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
    // #4473: the engine-neutral local polish contracts. Exposed beside LLM, which depends on
    // it, so a harness that links LLM resolves it as a product too.
    .library(name: "EnviousWisprLocalPolish", targets: ["EnviousWisprLocalPolish"]),
    // #4473: the llama-server engine (S1-mini, and EG-1 until its own engine lands). Exposed
    // like its dependencies; only the app shell and the unit tests import it.
    .library(name: "EnviousWisprLlamaEngine", targets: ["EnviousWisprLlamaEngine"]),
    // Exposed for the alias-suggestion eval harness at
    // scripts/eval/alias_runner. Purely additive — no production code
    // imports change. (#637)
    .library(name: "EnviousWisprPostProcessing", targets: ["EnviousWisprPostProcessing"]),
    // Exposed for eval harnesses that link the ASR module. #1276 PR-2 added it for a
    // tail-finalization runner (scripts/eval/tail_runner) that has since been removed.
    // Purely additive — no production code imports change.
    .library(name: "EnviousWisprASR", targets: ["EnviousWisprASR"]),
    // Exposed for the deterministic-layer polish harness at
    // scripts/eval/deterministic_runner, which grades SHIPPED behaviour by
    // running the real TextProcessingSteps around polish instead of sending raw
    // corpus text straight to a connector. Every eval harness before this one
    // measured polish naked, so deterministic wins (numbers, fillers, emoji
    // restore) counted as product failures — deterministic-features.md
    // FACT: benchmark-bypasses-this-whole-layer. Importing the steps THEMSELVES
    // is the point: re-implementing them in the harness would grade a copy
    // (validation-discipline.md RULE: measure-with-the-real-tool-never-a-simulation).
    // Purely additive — no production code imports change.
    .library(name: "EnviousWisprPipeline", targets: ["EnviousWisprPipeline"]),
    // #3735: exported so the Tuist graph can link and embed the transcribe.cpp
    // binary framework through `.package(product: "CTranscribe")`, the same way it
    // consumes Sparkle and the other external products.
    .library(name: "CTranscribe", targets: ["CTranscribe"]),
    // #4355: exported so the Tuist graph can link and embed the meeting echo cleaner
    // binary framework through `.package(product: "CWebRTCAEC")`, as CTranscribe above.
    .library(name: "CWebRTCAEC", targets: ["CWebRTCAEC"]),
  ],
  dependencies: [
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
    // #3546: branch `ew/3546-ultra-v0.17.7-signal` = `ew/3546-ultra-v0.17.7` (upstream
    // v0.17.7 503b4bd plus the two carries: terminal-token protection with dormant
    // vocabulary policy, and the outer-window fresh-state invariant) plus one observation
    // carry: `SlidingWindowAsrManager(onWindowInferenceEntered:)`, called immediately
    // before each window's model call (live-mode inference attribution). Keep both
    // branches permanently: SPM fetches this exact commit, which must remain reachable,
    // and the evaluation pinned the parent 6efc52ec.
    //
    // `traits: []` opts out of FluidAudio's default `NemoTextProcessing` trait.
    // The app does not use that text-normalization engine. Its v0.3.1 module-map
    // layout breaks our Xcode explicit-module build.
    // Tools 6.2 selects FluidAudio's trait-aware manifest; its older manifest
    // always links the engine.
    .package(
      url: "https://github.com/saurabhav88/FluidAudio.git",
      revision: "fb506037d2b1917dbb2608b8e79872ec95acf384", traits: []),
    // #3242: the learned-word check for engines without their own (Kev, a Qwen3.5 decision model) runs on
    // MLX, through two forks each carrying the smallest change on top of upstream. #4473 P2 adds what the
    // EnviousDecode engine needs to the same two forks:
    // - mlx-swift-lm (upstream ee673d6): two access changes in Qwen35.swift so the final-norm hidden
    //   states are reachable without lm_head (Kev's backbone call, kept as it is), and its mlx-swift
    //   dependency pointed at the fork below. For #4473: a gated-delta tape-recording hook and its
    //   forwarding through Qwen 3.5 (an armed cache leaves the compiled single-token routes), a capturing
    //   forward with public read access to the embedding and the output head, MambaCache open so a
    //   rollback cache can subclass it from another module, and test bounds sized by measured float32
    //   matmul precision (upstream #649).
    // - mlx-swift (upstream 0.31.6): the CUDA build-tool plugin attached to Cmlx on Linux only. On Apple
    //   platforms it generates nothing, but its presence made every xcodebuild stop at "Validate plug-in".
    //   For #4473: the upstream #461 compiler-lock repair (CompiledFunction.lock / evalLock order), without
    //   which two threads evaluating MLX at once can deadlock for good.
    .package(
      url: "https://github.com/saurabhav88/mlx-swift-lm.git",
      revision: "57e8ebe2394edb9b9a5e93d55c7d9d849ba13246"),
    .package(
      url: "https://github.com/saurabhav88/mlx-swift",
      revision: "b2de81fbb2b8d250bff2eea9659ddfc7fdb4ebec"),
    .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0"),
    // #3685: qualified macOS artifact with native crash attribution/caller fixes.
    .package(
      url: "https://github.com/saurabhav88/sentry-cocoa.git",
      revision: "beaa5941c0057dccf8a17837103aea0ca1376afc"),
    // Test-only (#1741 Chunk 10): real Swift lexical/syntactic awareness for
    // EngineMutationInventoryFreezeTests's comment/string handling, replacing
    // a hand-rolled character scanner that hit diminishing returns across 5
    // Codex review rounds. 603.0.2 matches this project's Swift 6.3.3
    // toolchain (swift-syntax's own versioning: major version 60X aligns
    // with Swift 6.X). Depended on ONLY by the EnviousWisprTests test
    // target below — SwiftPM links a dependency only into targets that
    // import it, so this never reaches the shipped app or the XPC helper.
    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.2"),
    // #1677: international phone-number validation and formatting for the language cleanup
    // passes (country calling-code split, national-number patterns, metadata grouping). Pinned
    // EXACTLY: the metadata copy in EnviousWisprPostProcessing/Resources must be the bytes this
    // version ships (LanguagePhoneMetadataTests pins the hash). The library's own bundled loader
    // is never used; LanguagePhoneMetadata hands it that copy.
    .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit.git", exact: "5.0.11"),
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
    // #4473: engine-neutral local polish: what a local model IS to the app (identity, launch
    // spec, install state, manifest facts, transport failure), with no engine in it. Core and
    // ModelDelivery only: never LLM, never an engine module, never MLX. The engines and LLM
    // depend on it, never the reverse. Mirrors Project.swift.
    .target(
      name: "EnviousWisprLocalPolish",
      dependencies: ["EnviousWisprCore", "EnviousWisprModelDelivery"],
      path: "Sources/EnviousWisprLocalPolish"
    ),
    .target(
      name: "EnviousWisprPostProcessing",
      dependencies: [
        "EnviousWisprCore",
        .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
      ],
      path: "Sources/EnviousWisprPostProcessing",
      resources: [.process("Resources")]
    ),
    // The live preview limb (#1988, #2077): display-only recognizer engines, the
    // contract they answer, and the cap on retained text.
    //
    // A module because the limb boundary should be structural, not a convention.
    // Engine implementations here CANNOT import Audio, ASR, Pipeline, Services, or
    // any UI — the dependency list below is the enforcement, so no preview engine
    // can reach the recording path even by accident. That is what makes "the
    // preview can never break a dictation" a property of the build rather than a
    // promise in a comment.
    //
    // Deliberately does NOT depend on EnviousWisprAudio: engines are handed audio
    // samples, they never touch capture. The coordinator that polls for those
    // samples stays in the app shell, where recording and overlay coordination
    // belong. `EnviousWisprModelDelivery` joins this list when the downloadable
    // engine lands and not before.
    .target(
      name: "EnviousWisprLivePreview",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprPostProcessing",
      ],
      path: "Sources/EnviousWisprLivePreview"
    ),
    // #2108 (epic #2077 chunk 4). The Live Preview engine backed by the
    // downloadable universal model.
    //
    // A SEPARATE TARGET because the two obvious homes each fail, for opposite
    // reasons. `EnviousWisprLivePreview` cannot import ASR, and that restriction
    // is the mechanism making a preview engine unable to reach the recording
    // path — this is the first change to test it, so widening it would spend the
    // guarantee rather than honour it. `EnviousWisprAppKit` can import
    // everything, so placing the adapter there breaks no stated rule but puts
    // domain implementation in the app shell and leaves it able to reach Audio
    // and Pipeline forever after.
    //
    // This list is the point: it gets exactly the imports the adapter needs and
    // keeps out the ones it must not have. `scripts/check-dependency-direction.sh`
    // enforces it. Do not add Audio, Pipeline, AppKit or Services here.
    .target(
      name: "EnviousWisprWhisperPreviewAdapter",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprPostProcessing",
        "EnviousWisprLivePreview",
        "EnviousWisprASR",
        // #3735: the transcribe.cpp boundary for the Universal preview engine.
        "EnviousWisprTranscribeCpp",
      ],
      path: "Sources/EnviousWisprWhisperPreviewAdapter"
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
        "CWebRTCAEC",
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
      path: "Sources/EnviousWisprServices",
      // #4013: the bundled talker rules. Project.swift must say `hasResources: true` too.
      resources: [.process("Resources")]
    ),
    // #1525 PR I-B: isolates FluidAudio's raw error-classification behind a
    // small, internal-only target. `FluidAudio` exports a struct literally
    // named `FluidAudio` that shadows module-qualified lookup, and a bare
    // unqualified `ASRError` inside `EnviousWisprASR` silently resolves to the
    // app's OWN `ASRError` type instead (`swift-patterns.md` RULE:
    // fluidaudio-unqualified-symbols) — this target is the one place that
    // safely names FluidAudio's error types. No library product: nothing
    // outside this package needs to import it.
    .target(
      name: "EnviousWisprFluidAudioBridge",
      dependencies: [
        "FluidAudio"
      ],
      path: "Sources/EnviousWisprFluidAudioBridge"
    ),
    // #3735: transcribe.cpp (our fork with two additive Whisper APIs: language
    // log-probability and seek progress). Dynamic framework built with the unmodified
    // upstream `scripts/ci/build_xcframework.sh` (macOS slice, minimum macOS 14.0,
    // Metal library embedded); module name `CTranscribe`. A static ggml-metal link
    // without -force_load crashes at launch, which is why this is the dynamic build.
    .binaryTarget(
      name: "CTranscribe",
      url:
        "https://github.com/saurabhav88/transcribe.cpp/releases/download/ew-3735-v0.4.0.5/TranscribeCpp.xcframework.zip",
      checksum: "62e13128aed0df806e9b3bd0c33116a32980f703ff9f5658870c6d0dd437d640"
    ),
    // #4355: WebRTC AEC3 (webrtc-audio-processing v2.1) behind a narrow C boundary, the
    // meeting echo cleaner. Dynamic macOS arm64 framework, minimum macOS 14.0, built by
    // `Vendor/webrtc-aec/build-xcframework.sh` and served from our own R2 bucket
    // (`enviouslabs-models`, models.enviouswispr.com). Provenance:
    // Sources/EnviousWispr/Resources/webrtc-aec-PROVENANCE.md.
    .binaryTarget(
      name: "CWebRTCAEC",
      url:
        "https://models.enviouswispr.com/frameworks/cwebrtcaec/ew-4355.3/CWebRTCAEC.xcframework.zip",
      checksum: "20fc4c7c747bbf9b1ff0f537f5cb89140764105dd4329bc9167d467b69010ddc"
    ),
    // #3735: the thin Swift boundary over CTranscribe. Mechanism only (sessions,
    // runs, language probability, progress, abort, UTF-8 repair); no app policy.
    .target(
      name: "EnviousWisprTranscribeCpp",
      dependencies: ["CTranscribe"],
      path: "Sources/EnviousWisprTranscribeCpp"
    ),
    .target(
      name: "EnviousWisprASR",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprAudio",
        "EnviousWisprFluidAudioBridge",
        // #1707 Phase 3: TelemetryService (recoveryEngineActionDeferred) for
        // the EngineRecoveryGate mutation-claim guards on the idle-unload path.
        "EnviousWisprServices",
        "FluidAudio",
        // #3735: the transcribe.cpp boundary for the Whisper engine.
        "EnviousWisprTranscribeCpp",
      ],
      path: "Sources/EnviousWisprASR"
    ),
    .target(
      name: "EnviousWisprLLM",
      dependencies: [
        "EnviousWisprCore",
        // #1348 Phase 3: EG-1 polish delivery converges onto the shared engine
        // (downward edge, both above Core). Mirrors Project.swift.
        "EnviousWisprModelDelivery",
        // #4473: the engine-neutral local polish contracts (downward edge).
        "EnviousWisprLocalPolish",
        // #832/#913 PR8: public Argmax tokenizer surface for the output-safety
        // classifier pair-encoder seam (AutoTokenizerWrapper / TokenizerWrapper).
        .product(name: "ArgmaxOSS", package: "argmax-oss-swift"),
      ],
      path: "Sources/EnviousWisprLLM"
    ),
    // #4473: the llama-server engine: connectors, launch arguments, health probe, slot reader,
    // learned-word checker and summary call for models served by the bundled `llama-server`.
    // It sits ABOVE LLM and LocalPolish and is imported only by the app shell (composition)
    // and the unit tests; LLM, LocalPolish and Pipeline never import it. Mirrors Project.swift.
    .target(
      name: "EnviousWisprLlamaEngine",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprModelDelivery",
        "EnviousWisprLocalPolish",
        "EnviousWisprLLM",
      ],
      path: "Sources/EnviousWisprLlamaEngine"
    ),
    // #3242: the learned-word check for polish engines that have none of their own. A leaf over Core
    // so MLX never reaches the eval harnesses that link EnviousWisprLLM or EnviousWisprPipeline.
    .target(
      name: "EnviousWisprWordCheck",
      dependencies: [
        "EnviousWisprCore",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        // Qwen's tokenizer through the same public Argmax surface the output classifier uses.
        .product(name: "ArgmaxOSS", package: "argmax-oss-swift"),
      ],
      path: "Sources/EnviousWisprWordCheck"
    ),
    .target(
      name: "EnviousWisprPipeline",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprASR",
        "EnviousWisprAudio",
        "EnviousWisprLLM",
        // #4473: the engine-neutral local polish lifecycle (endpoint, runtime handles).
        "EnviousWisprLocalPolish",
        "EnviousWisprModelDelivery",
        "EnviousWisprPostProcessing",
        "EnviousWisprServices",
        "EnviousWisprStorage",
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
        "EnviousWisprLocalPolish",
        "EnviousWisprLlamaEngine",
        "EnviousWisprPostProcessing",
        "EnviousWisprLivePreview",
        // #2108: composition only — `WhisperPreviewDeliveryWiring` constructs the
        // adapter from the preview registration. The edge is one-way.
        "EnviousWisprWhisperPreviewAdapter",
        "EnviousWisprAudio",
        "EnviousWisprServices",
        "EnviousWisprASR",
        "EnviousWisprLLM",
        "EnviousWisprPipeline",
        "EnviousWisprContacts",
        // #3242: composition only. `WordCheckRuntime` owns the Kev model's load and unload.
        "EnviousWisprWordCheck",
        "FluidAudio",
        "Sparkle",
      ],
      path: "Sources/EnviousWisprAppKit",
      resources: [.process("Resources")]
    ),
    // #2455 C1 (#2458): the production composition root. Chooses the live
    // desktop-effect implementations and hands them to `WisprBootstrapper`,
    // whose init requires them.
    //
    // NOT yet the wall. EnviousWisprTests still links EnviousWisprServices in C1
    // and can construct `HotkeyService(telemetry: .live)` itself. What C1 buys is
    // that no IMPLICIT production assembly path exists, and that AppLive is the
    // only production-choice site. C2 (#2459) removes the live implementation
    // from what the test target may import, and replaces the Services edge with
    // EnviousWisprDesktopEffects, which the dep-direction gate then forbids the
    // test targets from importing.
    // #2455 C2 (#2459): the ONLY module holding Carbon and NSEvent calls. Absent
    // from EnviousWisprTests' dependency list on purpose.
    //
    // That absence is NOT self-enforcing under Xcode — an undeclared import of
    // this module from the test target compiles and links, because Xcode shares
    // one build-products search path (measured 2026-08-26). SwiftPM does enforce
    // it, and this manifest is what makes `swift build` reject it, but CI runs
    // Tuist and xcodebuild only. `scripts/check-dependency-direction.sh` is what
    // actually catches it on every run.
    // #2455 C4: a NON-SHIPPING library holding fakes both test targets need.
    // Not a `.testTarget`: SwiftPM does not let one test target depend on another,
    // and duplicating the fakes would let two copies drift apart silently.
    .target(
      name: "EnviousWisprAppKitTestSupport",
      dependencies: ["EnviousWisprAppKit", "EnviousWisprCore"],
      path: "Sources/EnviousWisprAppKitTestSupport"
    ),
    .target(
      name: "EnviousWisprDesktopEffects",
      dependencies: [
        "EnviousWisprAppKit",
        "EnviousWisprServices",
      ],
      path: "Sources/EnviousWisprDesktopEffects"
    ),
    .target(
      name: "EnviousWisprAppLive",
      dependencies: [
        "EnviousWisprAppKit",
        "EnviousWisprDesktopEffects",
      ],
      path: "Sources/EnviousWisprAppLive"
    ),
    // #4473 P2: mirrors Project.swift's EnviousDecodeHelper, the second executable that ships inside
    // the app at Contents/MacOS/envious-decode. A leaf on MLX: it imports no first-party module, and
    // no library or test target depends on it.
    .executableTarget(
      name: "EnviousDecodeHelper",
      dependencies: [.product(name: "MLX", package: "mlx-swift")],
      path: "Sources/EnviousDecodeHelper"
    ),
    // #919: thin launchable shell. Owns @main + the AppDelegate adaptor +
    // app identity/Resources; delegates ALL construction + lifecycle downward.
    // #2455 C1: depends ONLY on EnviousWisprAppLive.
    .executableTarget(
      name: "EnviousWispr",
      dependencies: [
        "EnviousWisprAppLive"
      ],
      path: "Sources/EnviousWispr",
      exclude: ["Resources"]
    ),
    // #2455 C4: the only test target the dep-direction gate permits to construct a
    // live desktop effect. Nothing in the module graph enforces that — the gate does.
    // Three suites live here, each of which DELIBERATELY drives a real window:
    // `LiveOverlayPanelDriverTests`, `OverlayRetainedWindowRealPanelTests`, and
    // `RecordingPollingRealPanelTests`. `OverlayHostingParityTests` is NOT one of
    // them — with the panel injected it compares two host implementations and
    // needs no live effect, so it stays in the unit target.
    .testTarget(
      name: "EnviousWisprDesktopEffectsTests",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprAppKit",
        "EnviousWisprAppKitTestSupport",
        "EnviousWisprDesktopEffects",
      ],
      path: "Tests/EnviousWisprDesktopEffectsTests"
    ),
    .testTarget(
      name: "EnviousWisprTests",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprObservabilityCore",
        "EnviousWisprModelDelivery",
        "EnviousWisprLocalPolish",
        "EnviousWisprLlamaEngine",
        "EnviousWisprPostProcessing",
        "EnviousWisprLLM",
        "EnviousWisprPipeline",
        "EnviousWisprStorage",
        "EnviousWisprAudio",
        "EnviousWisprLivePreview",
        "EnviousWisprWhisperPreviewAdapter",
        // #1525 PR I-B (Codex cloud review): ParakeetTranscriptionSentryErrorTests /
        // ParakeetModelLoadSentryErrorTests import this directly.
        "EnviousWisprFluidAudioBridge",
        // #919: link the app-shell code from the library, NOT the app target,
        // so `swift test` / `xcodebuild test` never launch the app.
        "EnviousWisprAppKit",
        "EnviousWisprAppKitTestSupport",
        "EnviousWisprContacts",
        // #3242: KevEncodingTests exercise the word check's encoder directly.
        "EnviousWisprWordCheck",
        // #3735: WhisperGGUFRealDeliveryTests decode the admitted model directly.
        "EnviousWisprTranscribeCpp",
        // #1741 Chunk 10: EngineMutationInventoryFreezeTests's real Swift
        // parser (replaces its hand-rolled comment/string scanner). This is
        // the ONLY place swift-syntax is depended on in this package.
        // `SwiftOperators` (operator-sequence folding) was added in round 2
        // and removed in the council-approved contract pivot — it existed
        // only to resolve a call's callee, which the current
        // reference-inventory design no longer attempts.
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
      ],
      path: "Tests/EnviousWisprTests"
    ),
    .testTarget(
      name: "EnviousWisprASRTests",
      dependencies: [
        "EnviousWisprCore",
        "EnviousWisprASR",
        // #1525 PR I-B: the bridge classification tests import this directly,
        // not transitively through EnviousWisprASR.
        "EnviousWisprFluidAudioBridge",
        "FluidAudio",
        // #3735: TranscribeCppRealBoundaryTests drive the native boundary directly.
        "EnviousWisprTranscribeCpp",
      ],
      path: "Tests/EnviousWisprASRTests"
    ),
  ],
  swiftLanguageModes: [.v6]
)
