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

// Per-config IDENTITY (bundle id + Sparkle feed) is set on every config. The
// `.dev` identity lives on BOTH Debug (PR2, kept for CI's unsigned debug build)
// AND Dev (the local signed bundle). Dev additionally carries self-signed manual
// signing + the `EnviousWispr Local` product name. Release carries production
// identity (signing handled at archive/export time in PR5/PR6, NOT here). (#913)
let appSettings = targetSettings(
  debugExtra: [
    "PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.app.dev",
    "SU_FEED_URL": "",
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

let audioServiceSettings = targetSettings(
  debugExtra: ["PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.audioservice.dev"],
  devExtra: devSigningSettings.merging(
    ["PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.audioservice.dev"]) { _, new in new },
  releaseExtra: ["PRODUCT_BUNDLE_IDENTIFIER": "com.enviouswispr.audioservice"]
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

    // #919: app-shell library (homes + views + composition root + the
    // WisprBootstrapper front door). The unit-test target links THIS, so
    // `xcodebuild test` never launches the app. WhisperKit/FluidAudio/Sparkle
    // declared directly because Xcode doesn't propagate them transitively.
    firstPartyLibrary(
      "EnviousWisprAppKit",
      dependencies: firstPartyTargetDeps + [
        .package(product: "WhisperKit"),
        .package(product: "FluidAudio"),
        .package(product: "Sparkle"),
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
      // #919: the thin shell links ONLY the kit (the kit static-links the
      // engine modules + WhisperKit + FluidAudio). Sparkle stays a direct app
      // dep so Tuist embeds Sparkle.framework into the .app; the two XPC
      // services stay direct so they bundle into Contents/XPCServices.
      dependencies: [
        .target(name: "EnviousWisprAppKit"),
        .package(product: "Sparkle"),
        .target(name: "EnviousWisprAudioService"),
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
        configuration: "Release"
      )
    ),
  ]
)
