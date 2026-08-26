import ProjectDescription

let appBundleId = "com.enviouswispr.app"
let asrServiceBundleId = "com.enviouswispr.asrservice"

let deploymentTargets: DeploymentTargets = .macOS("14.0")

// One stable Swift package-access identifier shared by every first-party
// module + app + XPC + test target. This is what lets Swift `package`-level
// symbols cross our native module boundaries (SE-0386). It is deliberately a
// fixed string, NOT derived from the checkout directory, so it is identical in
// the root checkout, side-worktrees, and CI. (#913 PR1 — decided by 3-way
// consensus: Codex + council GPT/Gemini; see learnings ledger.)
let packageAccessIdentifier = "enviouswispr"

/// Mirrors `DesktopEffectPolicy.environmentKey` in EnviousWisprServices. Two
/// spellings of one name is how a gate goes quietly dead, so any change to either
/// must change both; `DesktopEffectPolicyTests` fails if they drift.
let DesktopEffectsPolicyKey = "EW_DESKTOP_EFFECTS_POLICY"

/// Mirrors `DesktopEffectDenial.trapEnvironmentKey`. Separate from the policy key
/// so a shipped app that somehow sees ONLY the policy variable loses its hotkeys
/// rather than crashing, while every TEST configuration — Debug, Dev and Release
/// alike — aborts on an unhandled refusal. Selecting that severity with
/// `#if DEBUG` instead would let the Release suite pass having reached a
/// prohibited effect (Codex chunk review, 2026-08-26).
let DesktopEffectsTrapKey = "EW_DESKTOP_EFFECTS_TRAP_DENIALS"

let commonSettings: SettingsDictionary = [
  "ARCHS": "arm64",
  "VALID_ARCHS": "arm64",
  "ONLY_ACTIVE_ARCH": "NO",
  "MACOSX_DEPLOYMENT_TARGET": "14.0",
  "SWIFT_VERSION": "6.0",
  "SWIFT_STRICT_CONCURRENCY": "complete",
  "SUPPORTED_PLATFORMS": "macosx",
  "SWIFT_PACKAGE_NAME": SettingValue(stringLiteral: packageAccessIdentifier),
  "CODE_SIGNING_ALLOWED": "NO",
  "CODE_SIGNING_REQUIRED": "NO",
]

// Performance-correctness: optimization is set EXPLICITLY per configuration so
// it is never silently left at a default. Release must match `swift build -c
// release` (full whole-module optimization) so the Xcode-built app runs exactly
// as fast as today's hand-rolled build. (#913 — founder directive: optimize for
// performance, not convenience.)
let debugConfigSettings: SettingsDictionary = [
  "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
  "SWIFT_COMPILATION_MODE": "singlefile",
  "GCC_OPTIMIZATION_LEVEL": "0",
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG",
  "GCC_PREPROCESSOR_DEFINITIONS": "$(inherited) DEBUG=1",
]

let releaseConfigSettings: SettingsDictionary = [
  "SWIFT_OPTIMIZATION_LEVEL": "-O",
  "SWIFT_COMPILATION_MODE": "wholemodule",
  "GCC_OPTIMIZATION_LEVEL": "s",
]

// Dev config: identical compiler flags to Debug (DEBUG defined → AppLogger file
// logging on, -Onone, fast incremental). It exists as a SEPARATE configuration
// so the dev-only self-signed signing + the `EnviousWispr Local` product naming
// live here and NEVER touch the CI-load-bearing Debug config (CI's hosted runner
// has no `EnviousWispr Dev` cert). (#913 PR4 — Codex-grounded reconciliation.)
let devConfigSettings: SettingsDictionary = debugConfigSettings

// Dev-only manual signing with the self-signed `EnviousWispr Dev` cert. Merged
// ONLY into the Dev config of the 3 signable bundles (app + 2 XPC). Debug and
// Release inherit `CODE_SIGNING_ALLOWED=NO` from `commonSettings`, so CI (which
// builds Debug + Release) never depends on the local-only cert. (#913 PR4.)
let devSigningSettings: SettingsDictionary = [
  "CODE_SIGNING_ALLOWED": "YES",
  "CODE_SIGNING_REQUIRED": "YES",
  "CODE_SIGN_STYLE": "Manual",
  "CODE_SIGN_IDENTITY": "EnviousWispr Dev",
  "OTHER_CODE_SIGN_FLAGS": "--timestamp=none",
]

let projectSettings = Settings.settings(
  base: commonSettings,
  configurations: [
    .debug(name: "Debug", settings: debugConfigSettings),
    .debug(name: "Dev", settings: devConfigSettings),
    .release(name: "Release", settings: releaseConfigSettings),
  ]
)

// Per-target settings = the common base + per-config optimization + per-config
// identity overrides (bundle id / Sparkle feed). Debug carries the `.dev`
// identity (isolates TCC/Keychain and blanks the update feed); Release carries
// the production identity. The three Info.plists reference
// `$(PRODUCT_BUNDLE_IDENTIFIER)` and `$(SU_FEED_URL)` so these reach the signed
// products. (#913 PR2)
func targetSettings(
  debugExtra: SettingsDictionary = [:],
  devExtra: SettingsDictionary = [:],
  releaseExtra: SettingsDictionary = [:]
) -> Settings {
  Settings.settings(
    base: commonSettings,
    configurations: [
      .debug(
        name: "Debug",
        settings: debugConfigSettings.merging(debugExtra) { _, new in new }
      ),
      .debug(
        name: "Dev",
        settings: devConfigSettings.merging(devExtra) { _, new in new }
      ),
      .release(
        name: "Release",
        settings: releaseConfigSettings.merging(releaseExtra) { _, new in new }
      ),
    ]
  )
}

// TEST targets only. Identical to `projectSettings` in Debug and Dev; the Release
// configuration drops optimization for the two unit-test bundles and nothing else.
//
// Why: `EnviousWisprTests` is one 128,735-line module, and compiling it at
// `-O`/`wholemodule` is the single most expensive thing in CI. Measured on PR run
// 31969994752, step `Build for testing (release, Xcode)`: the line
// `SwiftDriver Compilation EnviousWisprTests normal arm64` at 20:25:13 to the step
// end at 20:37:35 is 742 seconds — 12m22s optimizing test code that this step then
// throws away without executing. The whole PR wall clock was ~28 minutes.
//
// What the Release TEST build is for is a CONFIGURATION check, not an optimization
// one: a test file referencing a `#if DEBUG`-only Sources symbol without gating
// itself compiles in Debug and vanishes in Release (pr-check.yml's
// `Build for testing (release, Xcode)`; recurred twice in three days, #1358/#1498
// and #1536/#1538). `DEBUG` comes from SWIFT_ACTIVE_COMPILATION_CONDITIONS
// (`debugConfigSettings` above), never from SWIFT_OPTIMIZATION_LEVEL, so that
// entire failure class — plus type checking, Sendable, actor isolation, access
// control, `@testable` resolution, and test-bundle linking — is untouched here.
//
// Deliberately NOT set on the xcodebuild command line: a command-line
// `SETTING=value` has highest precedence and applies to EVERY target in the
// invocation, which would de-optimize the PRODUCT modules too. Per-target is what
// the intent actually is, and it keeps `main-post-merge.yml`'s release suite
// running unoptimized tests against fully optimized product code — so the
// Debug/Release behavioural divergences that job exists to catch (#2070/#2083,
// `Parser.defaultMaximumNestingLevel` is 20 under `#if DEBUG` and 256 otherwise)
// stay caught.
//
// The one thing this gives up: optimization-sensitive behavior inside TEST code,
// the reachable case being a side effect inside `assert(...)`, which `-O` strips
// and `-Onone` keeps. Verified empty at the time of writing — `grep -rnE
// "(^|[^.A-Za-z])assert\(" Tests/` returns 0 hits and there is no
// `_isDebugAssertConfiguration` anywhere in the repo. Do not put a side effect
// inside an `assert` in a test; use `#expect` or `precondition`.
//
// DEBUGGING POINTER, and the honest cost of this setting. Debug and Release now
// compile TEST code differently in one more way than before, so a lane-specific
// failure has one more axis to hide along. #2070 is the cautionary case: a test
// passed in one configuration and failed in the other because
// `Parser.defaultMaximumNestingLevel` is 20 under `#if DEBUG` and 256 otherwise,
// costing ~40 minutes of red main (#2083). Ladder for a suspicious failure, in
// order, because "just re-run it" cannot tell these apart:
//   fails under load, passes isolated ....... machine contention (or app.log
//                                             corruption if it is an AppLogger
//                                             test: those write a marker to the
//                                             shared log and read it back, so a
//                                             second concurrent appender breaks
//                                             UTF-8 boundaries and the read
//                                             returns empty — #2080)
//   fails isolated in Debug, passes Release .. configuration divergence
//   fails isolated in BOTH ................... now it is the diff
// Measured when this landed, so a future reader has a reference point: Debug
// executed 5,631 tests and Release 5,197, a 434 gap. That gap is structural, not
// a regression — `#if DEBUG` tests do not exist in the Release binary at all.
// Compare Release against a Release baseline, never against Debug.
let testTargetSettings = targetSettings(
  releaseExtra: [
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    "SWIFT_COMPILATION_MODE": "singlefile",
  ]
)

// Per-config IDENTITY (bundle id + Sparkle feed) is set on every config. The
// `.dev` identity lives on BOTH Debug (PR2, kept for CI's unsigned debug build)
// AND Dev (the local signed bundle). Dev additionally carries self-signed manual
// signing + the `EnviousWispr Local` product name. Release carries production
// identity (signing handled at archive/export time in PR5/PR6, NOT here). (#913)
let appSettings = targetSettings(
  debugExtra: [
    "PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.app.dev",
    "SU_FEED_URL": "",
    // #913: Debug carries the `.dev` bundle id and is unsigned
    // (CODE_SIGNING_ALLOWED=NO), but the base target entitlements are the PROD
    // file (which now carries application-identifier/team-identifier for the
    // embedded provisioning profile). Route Debug to the Dev entitlements too so
    // the unsigned CI build never carries a prod application-identifier under a
    // `.dev` bundle id. Inert today, prevents a future signed-Debug trap.
    "CODE_SIGN_ENTITLEMENTS": "Sources/EnviousWispr/Resources/EnviousWispr-Dev.entitlements",
  ],
  devExtra: devSigningSettings.merging([
    "PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.app.dev",
    "SU_FEED_URL": "",
    // The local dev app is named "EnviousWispr Local.app" (distinct from the
    // prod "EnviousWispr.app"), but the executable + CFBundleExecutable stay
    // "EnviousWispr" so hook/process checks (`pgrep -x EnviousWispr`) match.
    "PRODUCT_NAME": "EnviousWispr Local",
    "WRAPPER_NAME": "EnviousWispr Local.app",
    "EXECUTABLE_NAME": "EnviousWispr",
    // Dev signs with the self-signed cert (no team), so it CANNOT carry the
    // team-prefixed keychain-access-groups entitlement (that forces a
    // provisioning profile). The dev build uses the file-storage keychain
    // backend anyway, so a Dev entitlements file without the group is correct.
    "CODE_SIGN_ENTITLEMENTS": "Sources/EnviousWispr/Resources/EnviousWispr-Dev.entitlements",
  ]) { _, new in new },
  releaseExtra: [
    "PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.app",
    "SU_FEED_URL": "https://enviouswispr.com/appcast.xml",
  ]
)

let asrServiceSettings = targetSettings(
  debugExtra: ["PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.asrservice.dev"],
  devExtra: devSigningSettings.merging(
    ["PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.asrservice.dev"]) { _, new in new },
  releaseExtra: ["PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.asrservice"]
)

// First-party modules are NATIVE Tuist targets, statically linked. The app and
// both XPC services each get their own copy of the code they need (no runtime
// @rpath dependency on internal frameworks) — matching the current SwiftPM
// behavior and the lowest-risk shape for heart-path XPC launch.
func firstPartyLibrary(
  _ name: String,
  dependencies: [TargetDependency],
  hasResources: Bool = false
) -> Target {
  .target(
    name: name,
    destinations: .macOS,
    product: .staticFramework,
    bundleId: "com.enviouswispr.\(name)",
    deploymentTargets: deploymentTargets,
    infoPlist: .default,
    // A module's Resources/ is data, never compile sources — exclude it from
    // the source glob unconditionally. (#913 PR8: EnviousWisprLLM/Resources now
    // holds a .mlpackage whose inner model.mlmodel would otherwise be swept in
    // as a CoreML source of this static-framework target, which has no CoreML
    // build phase. Those files ride the APP target's resources instead.)
    sources: [.glob("Sources/\(name)/**", excluding: ["Sources/\(name)/Resources/**"])],
    resources: hasResources ? ["Sources/\(name)/Resources/**"] : [],
    dependencies: dependencies,
    settings: projectSettings
  )
}

let firstPartyTargetDeps: [TargetDependency] = [
  .target(name: "EnviousWisprCore"),
  .target(name: "EnviousWisprStorage"),
  .target(name: "EnviousWisprModelDelivery"),
  .target(name: "EnviousWisprPostProcessing"),
  .target(name: "EnviousWisprAudio"),
  .target(name: "EnviousWisprServices"),
  .target(name: "EnviousWisprASR"),
  .target(name: "EnviousWisprLLM"),
  .target(name: "EnviousWisprPipeline"),
]

/// #2455 C0 (#2457). For the duration of a test run, denies the desktop effects
/// C0 guards: Carbon hotkey registration, the Carbon event handler, and the
/// `NSEvent` modifier monitors. Overlay windows and app activation are the same
/// root cause and are NOT covered — those are C3 (#2460) and C4 (#2461).
///
/// The effect this buys: the unit suite stops registering real global hotkeys on
/// the developer's machine, where a registered Escape swallows Escape system-wide
/// for as long as the suite runs.
///
/// On the TEST action only. Xcode never applies a test action's environment to a
/// run, profile or archive action, and no shipped app is launched through a
/// scheme at all, so this cannot reach a user. `scripts/xcode-test.sh` and CI
/// both select these shared schemes, so neither needs its own copy of the
/// variable — one owner, per `GR-WRITE-FOR-RETRIEVAL`.
///
/// Removed or demoted in C5 (#2462), once the module boundary makes a live effect
/// unlinkable from the unit target and this tripwire is redundant.
let denyDesktopEffects: Arguments = .arguments(
  environmentVariables: [
    DesktopEffectsPolicyKey: .environmentVariable(value: "deny", isEnabled: true),
    DesktopEffectsTrapKey: .environmentVariable(value: "1", isEnabled: true),
  ]
)

let project = Project(
  name: "EnviousWispr",
  organizationName: "Envious Labs",
  packages: [
    // Brings the root SwiftPM package so external products (WhisperKit,
    // FluidAudio, Sparkle, PostHog, Sentry) resolve through its pinned
    // dependencies. First-party libs are NOT consumed as products — they are
    // the native targets below.
    .local(path: ".")
  ],
  settings: projectSettings,
  targets: [
    // ---- first-party modules (native static frameworks) ----
    firstPartyLibrary("EnviousWisprCore", dependencies: []),
    // Sentry-only privacy + crash-reporting leaf (#1174). The single home for
    // the event sanitizer + the helper Sentry bootstrap, shared by the app (via
    // Services) AND both XPC helpers — so the redactor has one source of truth
    // and the Sentry SDK stays contained to exactly the modules that need it.
    firstPartyLibrary(
      "EnviousWisprObservabilityCore",
      dependencies: [
        .package(product: "Sentry")
      ]),
    firstPartyLibrary(
      "EnviousWisprStorage",
      dependencies: [
        .target(name: "EnviousWisprCore")
      ]),
    // #1348 Phase 2: owned model-delivery layer. Leaf: Core only (D4
    // placement — never imports ASR/LLM/Pipeline; consumers import it).
    firstPartyLibrary(
      "EnviousWisprModelDelivery",
      dependencies: [
        .target(name: "EnviousWisprCore")
      ]),
    firstPartyLibrary(
      "EnviousWisprPostProcessing",
      dependencies: [
        .target(name: "EnviousWisprCore")
      ], hasResources: true),
    firstPartyLibrary(
      "EnviousWisprAudio",
      dependencies: [
        .target(name: "EnviousWisprCore"),
        .package(product: "FluidAudio"),
      ]),
    firstPartyLibrary(
      "EnviousWisprServices",
      dependencies: [
        .target(name: "EnviousWisprCore"),
        .target(name: "EnviousWisprObservabilityCore"),
        .package(product: "PostHog"),
        .package(product: "Sentry"),
      ]),
    // #1525 PR I-B: isolates FluidAudio's raw error-classification behind a
    // small, internal-only leaf. Consumed only by EnviousWisprASR and its
    // test target, so it is declared explicitly there rather than added to
    // the shared `firstPartyTargetDeps` engine set (same pattern as
    // EnviousWisprContacts above).
    firstPartyLibrary(
      "EnviousWisprFluidAudioBridge",
      dependencies: [
        .package(product: "FluidAudio")
      ]),
    firstPartyLibrary(
      "EnviousWisprASR",
      dependencies: [
        .target(name: "EnviousWisprCore"),
        .target(name: "EnviousWisprAudio"),
        .target(name: "EnviousWisprFluidAudioBridge"),
        // #1707 Phase 3: TelemetryService (recoveryEngineActionDeferred) for
        // the EngineRecoveryGate mutation-claim guards on the idle-unload path.
        .target(name: "EnviousWisprServices"),
        .package(product: "WhisperKit"),
        .package(product: "FluidAudio"),
      ]),
    firstPartyLibrary(
      "EnviousWisprLLM",
      dependencies: [
        .target(name: "EnviousWisprCore"),
        // #1348 Phase 3: EG-1 polish delivery converges onto the shared engine.
        // Downward edge (both sit above Core; ModelDelivery is a leaf).
        .target(name: "EnviousWisprModelDelivery"),
        // #832/#913 PR8: public Argmax tokenizer surface (AutoTokenizerWrapper /
        // TokenizerWrapper) for the output-safety classifier's pair-encoder seam.
        .package(product: "ArgmaxOSS"),
      ]),
    firstPartyLibrary(
      "EnviousWisprPipeline",
      dependencies: [
        .target(name: "EnviousWisprCore"),
        .target(name: "EnviousWisprASR"),
        .target(name: "EnviousWisprAudio"),
        .target(name: "EnviousWisprLLM"),
        .target(name: "EnviousWisprModelDelivery"),
        .target(name: "EnviousWisprPostProcessing"),
        .target(name: "EnviousWisprServices"),
        .target(name: "EnviousWisprStorage"),
        // Transitive: Audio/ASR import FluidAudio, whose plain C-target modules
        // (FastClusterWrapper, MachTaskSelfWrapper) only land on a DIRECT
        // depender's module search path. Xcode (unlike SwiftPM) doesn't
        // propagate them transitively, so any module importing Audio/ASR must
        // re-declare FluidAudio for the .swiftmodule import-closure to resolve.
        .package(product: "FluidAudio"),
      ]),

    // App-layer-scoped leaf (Core only): the Contacts-framework shim for #636.
    // Consumed only by EnviousWisprAppKit + the test bundle, so it is added to
    // those targets explicitly rather than to the shared `firstPartyTargetDeps`
    // engine set.
    firstPartyLibrary(
      "EnviousWisprContacts",
      dependencies: [
        .target(name: "EnviousWisprCore")
      ]),

    // The live preview limb (#1988, #2077). Same rationale as the SPM target:
    // the short dependency list IS the limb boundary, so no preview engine can
    // reach capture, ASR, the kernel or the paste path. Added to AppKit and the
    // test bundle explicitly, NOT to `firstPartyTargetDeps`, which would hand it
    // to unrelated targets that have no business seeing it.
    firstPartyLibrary(
      "EnviousWisprLivePreview",
      dependencies: [
        .target(name: "EnviousWisprCore"),
        .target(name: "EnviousWisprPostProcessing"),
      ]),

    // #2108 (epic #2077 chunk 4). The Live Preview engine backed by the
    // downloadable universal model. Its dependency list is the point: it needs
    // ASR, which is exactly why it cannot live in
    // EnviousWisprLivePreview above — and it must NOT gain Audio, Pipeline,
    // Services or AppKit. Added explicitly to AppKit and the test bundle rather
    // than to `firstPartyTargetDeps`, for the same reason LivePreview is.
    firstPartyLibrary(
      "EnviousWisprWhisperPreviewAdapter",
      dependencies: [
        .target(name: "EnviousWisprCore"),
        .target(name: "EnviousWisprPostProcessing"),
        .target(name: "EnviousWisprLivePreview"),
        .target(name: "EnviousWisprASR"),
        // NO `.target(name: "EnviousWisprModelDelivery")`. The limb receives
        // resolved paths and an admission ANSWER as values; giving it the
        // delivery module would let a future edit import a fetch-capable API
        // here with no check failing (cloud review r8).
        // FluidAudio, declared even though this module never references it.
        // Xcode does not propagate package products transitively (same reason
        // AppKit declares WhisperKit/FluidAudio/Sparkle directly), and linking
        // EnviousWisprASR pulls FluidAudio's C wrapper targets —
        // `FastClusterWrapper` and `MachTaskSelfWrapper` — which fail to resolve
        // without this. SwiftPM needs no such edge; only the Xcode graph does.
        .package(product: "FluidAudio"),
        // NO `.package(product: "WhisperKit")`. Every WhisperKit type stays
        // behind `WhisperPreviewRuntime` in ASR, and removing this edge was
        // verified not to be the cause of the wrapper-module failure above.
        // Matches Package.swift, which does not list it either.
      ]),

    // #919: app-shell library (homes + views + composition root + the
    // WisprBootstrapper front door). The unit-test target links THIS, so
    // `xcodebuild test` never launches the app. WhisperKit/FluidAudio/Sparkle
    // declared directly because Xcode doesn't propagate them transitively.
    firstPartyLibrary(
      "EnviousWisprAppKit",
      dependencies: firstPartyTargetDeps + [
        .target(name: "EnviousWisprContacts"),
        .target(name: "EnviousWisprLivePreview"),
        .target(name: "EnviousWisprWhisperPreviewAdapter"),
        .package(product: "WhisperKit"),
        .package(product: "FluidAudio"),
        .package(product: "Sparkle"),
      ],
      // #1487: bundled GPL-3.0.txt + THIRD-PARTY-NOTICES.txt for the in-app
      // Open Source Licenses screen, read via Bundle.module at runtime.
      hasResources: true),

    // ---- XPC services (audio capture is in-process since #1543; ASR stays isolated) ----
    .target(
      name: "EnviousWisprASRService",
      destinations: .macOS,
      product: .xpc,
      productName: "EnviousWisprASRService",
      bundleId: asrServiceBundleId,
      deploymentTargets: deploymentTargets,
      infoPlist: .file(path: "Sources/EnviousWisprASRService/Resources/Info.plist"),
      sources: ["Sources/EnviousWisprASRService/**"],
      entitlements: .file(
        path: "Sources/EnviousWisprASRService/Resources/EnviousWisprASRService.entitlements"),
      dependencies: [
        .target(name: "EnviousWisprCore"),
        .target(name: "EnviousWisprASR"),
        .target(name: "EnviousWisprAudio"),
        // Sentry-only crash-reporting bootstrap for this helper (#1174).
        .target(name: "EnviousWisprObservabilityCore"),
        .package(product: "WhisperKit"),
        .package(product: "FluidAudio"),
      ],
      settings: asrServiceSettings
    ),

    // ---- App ----
    .target(
      name: "EnviousWispr",
      destinations: .macOS,
      product: .app,
      productName: "EnviousWispr",
      bundleId: appBundleId,
      deploymentTargets: deploymentTargets,
      infoPlist: .file(path: "Sources/EnviousWispr/Resources/Info.plist"),
      sources: ["Sources/EnviousWispr/**"],
      // #832/#913 PR8: the on-device output-safety classifier rides the APP
      // target so its files land in EnviousWispr.app/Contents/Resources and
      // resolve at runtime via Bundle.main — NOT a SwiftPM module bundle.
      // Both are FOLDER REFERENCES: Tuist 4.195.11 recurses into a globbed
      // .mlpackage and fails to place its inner model.mlmodel in a build phase.
      // Xcode's Core ML build rule still compiles the referenced .mlpackage, so
      // what actually ships is OutputClassifier.mlmodelc and NOT the package —
      // verified against a built bundle (#1226, 2026-07-28). The on-device
      // MLModel.compileModel(at:) path in CoreMLOutputClassifier is therefore a
      // fallback that does not run in a normal build, not the normal route.
      // The tokenizer folder reference preserves the OutputClassifierTokenizer/
      // subdirectory verbatim. EnviousWisprLLM stays hasResources:false to
      // avoid double-bundling the same files into Bundle.module.
      resources: [
        "Sources/EnviousWispr/Resources/AppIcon.icns",
        .folderReference(path: "Sources/EnviousWisprLLM/Resources/OutputClassifier.mlpackage"),
        .folderReference(path: "Sources/EnviousWisprLLM/Resources/OutputClassifierTokenizer"),
        // #1386: the bundled WhisperKit tokenizer (Apache-2.0, pinned to a
        // frozen HF commit) — same Bundle.main folder-reference route as
        // OutputClassifierTokenizer above, for the same reason (a resource the
        // downstream module resolves via an injected resourceURL, not
        // Bundle.module). EnviousWisprASR stays hasResources:false.
        .folderReference(path: "Sources/EnviousWisprASR/Resources/WhisperTokenizer"),
        // #2108: the Live Preview model's OWN tokenizer, at a hub-structured
        // path so WhisperKit resolves it by variant. It cannot share the folder
        // above: that one has a top-level tokenizer.json, which WhisperKit
        // matches variant-agnostically, so passing it for the small model loads
        // the LARGE-V3 vocabulary silently (measured: noSpeechToken 50363
        // instead of 50257, no error, fluent wrong output). ASR resources are
        // not otherwise embedded, so without this line the artifact ships in no
        // build and every on-disk test still passes.
        .folderReference(path: "Sources/EnviousWisprASR/Resources/WhisperPreviewTokenizer"),
        // #1271: EG-1 native polish — the model manifest and the bundled
        // llama-server inference binary ride the APP target (Bundle.main,
        // Contents/Resources), same route as the classifier above. The
        // binary is a nested Mach-O: build-dev-app.sh and
        // build-release-dmg.sh sign it in the inside-out order.
        "Sources/EnviousWispr/Resources/eg1-manifest.json",
        // #1348 Phase 2: Parakeet delivery manifest — the bundled trust root
        // (contract 4a). Same Bundle.main route as eg1-manifest.json.
        "Sources/EnviousWispr/Resources/parakeet-delivery-manifest.json",
        "Sources/EnviousWispr/Resources/whisperkit-delivery-manifest.json",
        // #2102 (epic #2077 chunk 3): the SECOND WhisperKit-family artifact —
        // the small multilingual model Live Preview offers as the universal
        // alternative to Apple's engine. Listed individually because this array
        // is the only thing that bundles a manifest; nothing globs Resources/,
        // so a file merely placed beside its siblings ships in no build.
        // Nothing loads it until the preview recognizer arrives (chunk 4).
        "Sources/EnviousWispr/Resources/whisperkit-preview-delivery-manifest.json",
        // #1348 Phase 3: EG-1 delivery manifest — the DELIVERY trust root for
        // EG-1's convergence onto the shared engine (the runtime trust root
        // stays eg1-manifest.json). Same Bundle.main route.
        "Sources/EnviousWispr/Resources/eg1-delivery-manifest.json",
        "Sources/EnviousWispr/Resources/llama-server",
        // #1224 (#1543): the bundled VAD model for `CaptureVADSignalSource`'s
        // in-process VAD loop. Relocated into the app target's own resources
        // when audio capture came in-process and the separate capture helper
        // was deleted. Folder-referenced so Tuist embeds the `.mlmodelc` verbatim.
        .folderReference(
          path:
            "Sources/EnviousWispr/Resources/VAD/silero-vad-unified-256ms-v6.0.0.mlmodelc"
        ),
      ],
      entitlements: .file(path: "Sources/EnviousWispr/Resources/EnviousWispr.entitlements"),
      // #919: the thin shell links ONLY the kit (the kit static-links the
      // engine modules + WhisperKit + FluidAudio). Sparkle stays a direct app
      // dep so Tuist embeds Sparkle.framework into the .app; the ASR XPC
      // service stays direct so it bundles into Contents/XPCServices (#1543:
      // the audio capture service was removed — capture is in-process).
      dependencies: [
        .target(name: "EnviousWisprAppKit"),
        .package(product: "Sparkle"),
        .target(name: "EnviousWisprASRService"),
      ],
      settings: appSettings
    ),

    // ---- Test bundles ----
    // This bundle's graph is intentionally BROADER than Package.swift's
    // testTarget list. SwiftPM let the test target name only a subset and
    // propagated the rest transitively. Xcode does not propagate, so every
    // module a test imports DIRECTLY must be a declared edge. Verified: tests
    // import all 8 first-party modules + EnviousWisprAppKit + FluidAudio +
    // Sparkle directly, so the full first-party set + the kit + those two
    // externals is the exact, minimal set.
    // #919: depends on EnviousWisprAppKit (the app-shell library), NOT the app
    // target — Tuist therefore wires NO test host, so `xcodebuild test` runs
    // hermetically without launching EnviousWispr.app.
    .target(
      name: "EnviousWisprTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "com.enviouswispr.tests",
      deploymentTargets: deploymentTargets,
      infoPlist: .default,
      sources: ["Tests/EnviousWisprTests/**"],
      dependencies: firstPartyTargetDeps + [
        .target(name: "EnviousWisprAppKit"),
        .target(name: "EnviousWisprContacts"),
        .target(name: "EnviousWisprLivePreview"),
        // #2108: the preview-engine tests import the adapter directly. Xcode
        // test targets need every direct import as a declared edge (#1174).
        .target(name: "EnviousWisprWhisperPreviewAdapter"),
        // HelperObservabilityConfigTests imports the module directly; Xcode test
        // targets need every direct import as a declared edge (#1174).
        .target(name: "EnviousWisprObservabilityCore"),
        // #1525 PR I-B (Codex cloud review): ParakeetTranscriptionSentryErrorTests /
        // ParakeetModelLoadSentryErrorTests import this directly.
        .target(name: "EnviousWisprFluidAudioBridge"),
        .package(product: "FluidAudio"),
        .package(product: "Sparkle"),
        // #1741 Chunk 10: EngineMutationInventoryFreezeTests's real Swift
        // parser. Test-target-only — never reaches the app or XPC targets
        // above (see Package.swift for the matching SPM dependency).
        // `SwiftOperators` was removed in the council-approved contract
        // pivot (no longer resolving callees, so no folding needed).
        .package(product: "SwiftParser"),
        .package(product: "SwiftSyntax"),
      ],
      settings: testTargetSettings
    ),
    .target(
      name: "EnviousWisprASRTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "com.enviouswispr.asrtests",
      deploymentTargets: deploymentTargets,
      infoPlist: .default,
      sources: ["Tests/EnviousWisprASRTests/**"],
      dependencies: [
        .target(name: "EnviousWisprCore"),
        .target(name: "EnviousWisprASR"),
        // #1525 PR I-B: the bridge classification tests import this
        // directly, not transitively through EnviousWisprASR.
        .target(name: "EnviousWisprFluidAudioBridge"),
        .package(product: "WhisperKit"),
        // Static-link FluidAudio: the test bundle links EnviousWisprASR (a
        // static framework that uses FluidAudio), so its symbols must be
        // resolved here too (Xcode doesn't propagate transitive static-link).
        .package(product: "FluidAudio"),
      ],
      settings: testTargetSettings
    ),
  ],
  schemes: [
    .scheme(
      name: "EnviousWispr",
      shared: true,
      buildAction: .buildAction(
        targets: ["EnviousWispr"],
        findImplicitDependencies: true
      ),
      testAction: .targets(
        ["EnviousWisprTests", "EnviousWisprASRTests"],
        arguments: denyDesktopEffects,
        configuration: "Debug"
      )
    ),
    // PR4: dev scheme — builds the app in the `Dev` config (self-signed
    // `EnviousWispr Local.app`). `scripts/build-dev-app.sh` + the dev rebuild
    // skills drive this; CI never selects it (CI uses `EnviousWispr`/Debug +
    // `EnviousWispr-Release`/Release). Test action runs in Dev (unsigned logic
    // tests, same DEBUG flags as Debug).
    .scheme(
      name: "EnviousWispr-Dev",
      shared: true,
      buildAction: .buildAction(
        targets: ["EnviousWispr"],
        findImplicitDependencies: true
      ),
      testAction: .targets(
        ["EnviousWisprTests", "EnviousWisprASRTests"],
        arguments: denyDesktopEffects,
        configuration: "Dev"
      )
    ),
    .scheme(
      name: "EnviousWispr-Release",
      shared: true,
      buildAction: .buildAction(
        targets: ["EnviousWispr"],
        findImplicitDependencies: true
      ),
      // PR3: release-config test action so main-post-merge can run
      // `xcodebuild test -scheme EnviousWispr-Release -configuration Release`,
      // preserving the release-config test coverage the old post-merge job ran.
      testAction: .targets(
        ["EnviousWisprTests", "EnviousWisprASRTests"],
        arguments: denyDesktopEffects,
        configuration: "Release"
      )
    ),
  ]
)
