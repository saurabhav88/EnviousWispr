import ProjectDescription

let appBundleId = "com.enviouswispr.app"
let audioServiceBundleId = "com.enviouswispr.audioservice"
let asrServiceBundleId = "com.enviouswispr.asrservice"

let deploymentTargets: DeploymentTargets = .macOS("14.0")

// One stable Swift package-access identifier shared by every first-party
// module + app + XPC + test target. This is what lets Swift `package`-level
// symbols cross our native module boundaries (SE-0386). It is deliberately a
// fixed string, NOT derived from the checkout directory, so it is identical in
// the root checkout, side-worktrees, and CI. (#913 PR1 — decided by 3-way
// consensus: Codex + council GPT/Gemini; see learnings ledger.)
let packageAccessIdentifier = "enviouswispr"

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

let projectSettings = Settings.settings(
  base: commonSettings,
  configurations: [
    .debug(name: "Debug", settings: debugConfigSettings),
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
  releaseExtra: SettingsDictionary = [:]
) -> Settings {
  Settings.settings(
    base: commonSettings,
    configurations: [
      .debug(
        name: "Debug",
        settings: debugConfigSettings.merging(debugExtra) { _, new in new }
      ),
      .release(
        name: "Release",
        settings: releaseConfigSettings.merging(releaseExtra) { _, new in new }
      ),
    ]
  )
}

// PR2 sets only the per-config IDENTITY (bundle id + Sparkle feed). The
// Apple-intended automatic-signing migration (Apple Development cert + Mac
// Development profile under DEVELOPMENT_TEAM=9UT54V24XG) lands in the dev-bundle
// PR (PR4) + release PRs (PR5/PR6), where signing is inherently needed and the
// founder's Apple Development cert is available. PR2 builds unsigned (like PR1),
// proving the resource accessor + dev identity independent of signing. (#913)
let appSettings = targetSettings(
  debugExtra: [
    "PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.app.dev",
    "SU_FEED_URL": "",
  ],
  releaseExtra: [
    "PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.app",
    "SU_FEED_URL": "https://enviouswispr.com/appcast.xml",
  ]
)

let audioServiceSettings = targetSettings(
  debugExtra: ["PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.audioservice.dev"],
  releaseExtra: ["PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.audioservice"]
)

let asrServiceSettings = targetSettings(
  debugExtra: ["PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.asrservice.dev"],
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
    sources: hasResources
      ? [.glob("Sources/\(name)/**", excluding: ["Sources/\(name)/Resources/**"])]
      : ["Sources/\(name)/**"],
    resources: hasResources ? ["Sources/\(name)/Resources/**"] : [],
    dependencies: dependencies,
    settings: projectSettings
  )
}

let firstPartyTargetDeps: [TargetDependency] = [
  .target(name: "EnviousWisprCore"),
  .target(name: "EnviousWisprStorage"),
  .target(name: "EnviousWisprPostProcessing"),
  .target(name: "EnviousWisprAudio"),
  .target(name: "EnviousWisprServices"),
  .target(name: "EnviousWisprASR"),
  .target(name: "EnviousWisprLLM"),
  .target(name: "EnviousWisprPipeline"),
]

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
    // ---- 8 first-party modules (native static frameworks) ----
    firstPartyLibrary("EnviousWisprCore", dependencies: []),
    firstPartyLibrary(
      "EnviousWisprStorage",
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
        .package(product: "PostHog"),
        .package(product: "Sentry"),
      ]),
    firstPartyLibrary(
      "EnviousWisprASR",
      dependencies: [
        .target(name: "EnviousWisprCore"),
        .target(name: "EnviousWisprAudio"),
        .package(product: "WhisperKit"),
        .package(product: "FluidAudio"),
      ]),
    firstPartyLibrary(
      "EnviousWisprLLM",
      dependencies: [
        .target(name: "EnviousWisprCore")
      ]),
    firstPartyLibrary(
      "EnviousWisprPipeline",
      dependencies: [
        .target(name: "EnviousWisprCore"),
        .target(name: "EnviousWisprASR"),
        .target(name: "EnviousWisprAudio"),
        .target(name: "EnviousWisprLLM"),
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

    // ---- XPC services ----
    .target(
      name: "EnviousWisprAudioService",
      destinations: .macOS,
      product: .xpc,
      productName: "EnviousWisprAudioService",
      bundleId: audioServiceBundleId,
      deploymentTargets: deploymentTargets,
      infoPlist: .file(path: "Sources/EnviousWisprAudioService/Resources/Info.plist"),
      sources: ["Sources/EnviousWisprAudioService/**"],
      entitlements: .file(
        path: "Sources/EnviousWisprAudioService/Resources/EnviousWisprAudioService.entitlements"),
      dependencies: [
        .target(name: "EnviousWisprCore"),
        .target(name: "EnviousWisprAudio"),
        // Transitive FluidAudio C-target modules (see Pipeline note above).
        .package(product: "FluidAudio"),
      ],
      settings: audioServiceSettings
    ),
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
      resources: [
        "Sources/EnviousWispr/Resources/AppIcon.icns"
      ],
      entitlements: .file(path: "Sources/EnviousWispr/Resources/EnviousWispr.entitlements"),
      dependencies: firstPartyTargetDeps + [
        .package(product: "WhisperKit"),
        .package(product: "FluidAudio"),
        .package(product: "Sparkle"),
        .target(name: "EnviousWisprAudioService"),
        .target(name: "EnviousWisprASRService"),
      ],
      settings: appSettings
    ),

    // ---- Test bundles ----
    // This bundle's graph is intentionally BROADER than Package.swift's
    // testTarget list. SwiftPM let the test target name only a subset and
    // propagated the rest transitively (e.g. FluidAudio/Sparkle via the app
    // dep, Services/ASR via Pipeline). Xcode does not propagate, so every
    // module a test imports DIRECTLY must be a declared edge. Verified: tests
    // import all 8 first-party modules + FluidAudio + Sparkle directly, so the
    // full first-party set + those two externals is the exact, minimal set.
    .target(
      name: "EnviousWisprTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "com.enviouswispr.tests",
      deploymentTargets: deploymentTargets,
      infoPlist: .default,
      sources: ["Tests/EnviousWisprTests/**"],
      dependencies: firstPartyTargetDeps + [
        .target(name: "EnviousWispr"),
        .package(product: "FluidAudio"),
        .package(product: "Sparkle"),
      ],
      settings: projectSettings
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
        .package(product: "WhisperKit"),
        // Static-link FluidAudio: the test bundle links EnviousWisprASR (a
        // static framework that uses FluidAudio), so its symbols must be
        // resolved here too (Xcode doesn't propagate transitive static-link).
        .package(product: "FluidAudio"),
      ],
      settings: projectSettings
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
        configuration: "Debug"
      )
    ),
    .scheme(
      name: "EnviousWispr-Release",
      shared: true,
      buildAction: .buildAction(
        targets: ["EnviousWispr"],
        findImplicitDependencies: true
      )
    ),
  ]
)
