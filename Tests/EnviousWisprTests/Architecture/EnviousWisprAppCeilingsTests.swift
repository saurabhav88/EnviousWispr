import Foundation
import Testing

/// Architecture regression tests for `EnviousWisprApp`.
///
/// PR-A of #763 installs `EnviousWisprApp` as the SwiftUI composition root.
/// This test caps it before PR5+ start adding more App-owned homes, so the
/// composition root cannot quietly accrete domain methods or imports.
///
/// Tests parse the source file directly — App-struct initialization mounts
/// the real app and is not unit-testable.
///
/// Ratchet wording: lower-is-free, raise-needs-Bible §30 entry.
@Suite struct EnviousWisprAppCeilingsTests {

  /// Stored-property ceiling on the App struct.
  /// Locked at post-PR7 baseline (#773, 2026-05-18) = 11:
  /// appDelegate + isOnboardingPresented + appState + navigationCoordinator +
  /// diagnosticsCoordinator + languageSuggestionPresenter + updateCoordinatorHolder
  /// + transcriptWorkflowCoordinator (PR6) + liveRecordingState +
  /// lastRecordingResult + backendMetadata (all PR7).
  /// Counts both `let` and `var` top-level declarations (property wrappers
  /// included). Primitives (`: Bool`, `: Int`, `: String`, `: Double`) are
  /// excluded so the bool-typed `isOnboardingPresented` does count via the
  /// `@State` wrapper presence rather than the type alone.
  ///
  /// Ratchet history:
  /// - 7 → 8 in PR6 of epic #763 (2026-05-18, #772) for `TranscriptWorkflowCoordinator`.
  /// - 8 → 11 in PR7 of epic #763 (2026-05-18, #773) for `LiveRecordingState` +
  ///   `LastRecordingResult` + `BackendMetadata`. Bible §30 entry: PR7 lifts the
  ///   three live-dictation / display-label homes off the former root state into App-owned
  ///   `@State` instances. By design, the former root state shrinks (~14 lines) while the
  ///   composition root grows by three; this is the migration shape.
  ///   `liveRecordingState` and `lastRecordingResult` sunset to 9 in PR9
  ///   (DictationLifecycleCoordinator absorbs the push sites);
  ///   `backendMetadata` sunsets to 8 in PR11 (with the former root state deletion).
  /// - 11 → 12 in PR8 of epic #763 (2026-05-19, #774) for `DictationRuntime`.
  /// - 12 → 13 in PR10 of epic #763 (2026-05-19, #776) for the shared
  ///   `HotkeyService`. Bible §30 entry: PR10 lifts `let hotkeyService` off
  ///   the former root state because three independent consumers (`HotkeyController`,
  ///   `PipelineSettingsSync`, `DictationLifecycleCoordinator`) plus
  ///   `AppDelegate` termination all need the SAME instance, and the former root state
  ///   is being deleted (epic #763 freeze). The App-owned `@State` is the
  ///   only composition root that survives PR11. Threaded into `the former root-state initializer`,
  ///   DLC.init, DR.init, and `appDelegate.attach(...)`.
  /// - 13 → 14 in PR-B.1 of epic #763 (2026-05-19, #796) for
  ///   `SparkleUpdateController`. Bible §30 entry: PR-B.1 lifts the Sparkle
  ///   integration off AppDelegate into a dedicated App-owned home. The
  ///   `@State` instance is constructed from `updateCoordinatorHolder` and
  ///   threaded into `appDelegate.attach(...)` so `applicationWillFinishLaunching`
  ///   can invoke `startUpdater()` synchronously before any SwiftUI scene
  ///   body evaluates (Issue #739 env-capture invariant).
  /// - 14 → 15 in PR-B.2 of epic #763 (2026-05-19, #797) for
  ///   `AppWindowCoordinator`. Bible §30 entry: PR-B.2 lifts window lifecycle
  ///   (main + onboarding window identity, the two close observers, the
  ///   SwiftUI open/dismiss bridges, activation-policy transitions) off
  ///   AppDelegate into a dedicated App-owned home. The `@State` instance is
  ///   constructed in `init()` with two onboarding-guard closures and threaded
  ///   into `appDelegate.attach(...)` plus injected into both Window scenes
  ///   via `.environment(...)`.
  /// - 15 → 16 in PR-B.3 of epic #763 (2026-05-20, #798) for
  ///   `MenuBarController`. Bible §30 entry: PR-B.3 lifts the menu bar surface
  ///   (status item, dropdown menu, animated icon, `NSMenuDelegate`, five menu
  ///   actions) off AppDelegate into a dedicated App-owned home. The `@State`
  ///   instance is constructed in `init()` with five menu-action closures and
  ///   threaded into `appDelegate.attach(...)`. Not `.environment(...)`-injected
  ///   — no SwiftUI view consumes the menu surface.
  /// - 16 → 17 in PR-B.4 of epic #763 (2026-05-20, #799) for
  ///   `AppLifecycleCoordinator`. Bible §30 entry: PR-B.4 lifts the
  ///   process-lifecycle sequence (launch / become-active / terminate side
  ///   effects, the three process-lifetime audio objects) off AppDelegate into
  ///   a dedicated App-owned home. The `@State` instance is constructed last in
  ///   `init()` from seven already-built dependencies and threaded into
  ///   `appDelegate.attach(...)`. This is the final PR-B home — `AppDelegate`
  ///   ends as a thin AppKit adapter. Not `.environment(...)`-injected.
  /// - 17 → 26 in PR-C.1 of epic #763 (2026-05-20, #813). Bible §30 entry:
  ///   PR-C.1 hoists the nine view-facing subsystems the former root state used to own
  ///   (`settings`, `permissions`, `asrManager`, `customWordsCoordinator`,
  ///   `setup`, `audioDeviceList`, `aiAvailability`, `keychainManager`,
  ///   `llmDiscovery`) into App-owned `@State` homes, injected into both Window
  ///   scenes. The seven construction-only subsystems stay `init()` locals and
  ///   are not counted.
  /// - 26 → 27 in PR-C.3 of epic #763 (2026-05-20, #815): PR-C.3 rehomed
  ///   `polishService` (the re-polish service) onto an App-owned `@State`.
  /// - 27 → 26 in PR-C.4 of epic #763 (2026-05-20, #816): PR-C.4 deleted the
  ///   receive-only root state property, the final step of the epic.
  ///   Lower-is-free.
  /// - 26 → 27 in #913 PR8 (2026-05-31, #832): App-owned `outputClassifierHolder`
  ///   for the on-device output-safety classifier (loaded async at prewarm,
  ///   injected into both kernel drivers + the re-polish service).
  /// - 27 → 28 in #633 Phase 9 (2026-06-06): App-owned `vocabularyPackManager`
  ///   for the opt-in word packs — owns enabled-pack state and merges pack
  ///   terms into the corrector lane, injected into the main Window scene.
  /// - 28 → 29 in #636 (2026-06-06): App-owned `contactsImportCoordinator` for
  ///   Import-from-Contacts — orchestrates the opt-in import + bulk-remove,
  ///   injected into the main Window scene and read by AppLifecycleCoordinator
  ///   for the opt-in launch sync. A narrow new coordinator (issue-636 §3b).
  /// - 29 → 30 in #1019 (2026-06-09): App-owned `updateTriggerCoordinator` for
  ///   always-on update discovery — translates OS wake/network signals into
  ///   proactive update checks for a never-foregrounded user. Data-free; holds
  ///   only the path monitor + wake latch (issue-1019 §3b). A narrow new home
  ///   keeping the composition root thin per `no-appcontainer`.
  /// - 30 → 29 in #1106 (2026-06-19): removed the re-polish feature.
  ///   `transcriptWorkflowCoordinator` collapsed into a direct
  ///   `transcriptCoordinator` env injection (net zero — a rename), and
  ///   `polishService` dropped (−1). Lower-is-free.
  /// - 30 → 31 in #1171 (2026-06-23, Telemetry Bible Phase 2): App-owned
  ///   `engineCoordinator` — the sole owner of ASR-engine selection, status, and
  ///   switching (reads the live selection + active engine, serializes switches
  ///   through one mailbox, publishes one `EngineStatus`). A narrow new App-owned
  ///   home that SHRINKS `PipelineSettingsSync` (three stored "want" vars + three
  ///   methods deleted) — exactly the #763 direction (many narrow homes, not god
  ///   objects). Injected into the main Window scene; consumed by `DictationRuntime`,
  ///   `RecoveryCoordinator`, `PipelineSettingsSync`, and the Settings affordance. The
  ///   pre-#1171 count was already at the cap (30), so adding one home needs +1.
  /// - 31 → 32 in #1173 (2026-06-23, Telemetry Bible Phase 4): App-owned
  ///   `settingsChangeTelemetry` — the settings-funnel observer that emits
  ///   coalesced `settings.changed` deltas + the onboarding-completion baseline.
  ///   A narrow new App-owned home (the #763 direction: many narrow homes), held
  ///   app-lifetime so it never deallocs and stops emitting. The pre-#1173 count
  ///   was already at the cap (31), so adding one home needs +1.
  /// - 32 → 33 in #1176 (2026-06-24, Telemetry Bible Phase 7): App-owned
  ///   `onboardingProgress` — the in-flight onboarding session box that owns the
  ///   single-terminal abandon dedup (complete / window-close / app-quit) and the
  ///   re-entry reset. Bootstrapper-owned so `applicationWillTerminate` can emit the
  ///   app-quit abandon and the App-layer window-close closure can call it, WITHOUT
  ///   adding a stored property to any coordinator (the #763 direction: many narrow
  ///   homes). The pre-#1176 count was already at the cap (32), so adding one home needs +1.
  /// - 33 → 34 in #1271 (2026-07-02, EG-1 native integration): App-owned
  ///   `egOneRuntime` — single owner of the first-party polish model store +
  ///   inference server, consumed by BOTH the pipeline (endpoint at polish
  ///   time) and the settings UI (download/health). The composition root is
  ///   the one valid home for a shared runtime (`state-ownership.md`
  ///   shared-infra-homes-not-feature-services; council round 1 rejected a
  ///   settings-setup owner). Plan §3b named this +1 as the accepted cost.
  /// - 34 → 35 in #1348 Phase 2 (2026-07-06): App-owned `modelDelivery` —
  ///   the owned model-delivery home (single `ModelDeliveryController` +
  ///   Parakeet registration from the bundled trust-root manifest +
  ///   `model_delivery.*` telemetry bridge + the observable UI mirror the
  ///   settings row renders). The composition root is the one valid home for
  ///   a shared delivery layer consumed by BOTH the Parakeet driver (via the
  ///   Pipeline handle) and the settings UI (Cancel/Resume) — same shape as
  ///   `egOneRuntime` above. The Phase 2 plan §3b/§14 named this +1 as the
  ///   accepted cost; pre-#1348 count was at the cap (34).
  /// - 35 → 36 in #1378 (2026-07-08): App-owned
  ///   `inputDevicePreferenceReconciler` keeps the microphone picker honest
  ///   when connected devices or the system default input change. The decision
  ///   rule lives in a pure policy function; the bootstrapper stores only the
  ///   app-lifetime wiring object.
  /// - 36 → 37 in #1386 PR-2 (2026-07-16): App-owned `activeEngine`, the one
  ///   door to whichever engine is active. "Load the active engine" stopped
  ///   being one call: WhisperKit must load in-process behind its relocation
  ///   gate, while Parakeet still goes through the ASR manager (and its XPC
  ///   helper). Two consumers need the SAME routing — crash recovery, which is
  ///   constructed here, and the Diagnostics benchmark, which reaches it through
  ///   the environment — which makes it composition-root plumbing by the same
  ///   rule as `modelDelivery` above. A narrower home was tried and rejected by
  ///   this suite's own design: `DiagnosticsCoordinator` is capped at exactly
  ///   one collaborator (`benchmark`), zero methods, 14 lines, so parking shared
  ///   engine routing there would have broken a TIGHTER, deliberate ceiling to
  ///   dodge this one. The stored value is a struct of three closures — routing,
  ///   no state, no policy — and its construction lives in
  ///   `ActiveEngineOperation.live`, not in the root.
  /// - 37 → 38 in #1386 PR-2b (2026-07-17): App-owned `whisperKitRetirement`,
  ///   the launch retire-and-refetch coordinator. It is reached only through a
  ///   closure `SetupCoordinator` calls once, and a closure capture cannot keep
  ///   it alive — as a weakly-captured local it deallocated before the deferred
  ///   phase ran and the retirement silently no-op'd (caught by Live UAT, not
  ///   by any static review). Storing it here IS the fix: nothing narrower owns
  ///   its lifetime, the same rule that placed `egOneRuntime` above.
  /// - 38 → 39 in #1701 (2026-07-23): App-owned
  ///   `bulkImportEnrichmentCoordinator`, the app-lifetime owner of the durable
  ///   pending-word drain and Cancel/checkpoint sequencing. The approved #1701
  ///   plan §3b/§10 places this sibling of `contactsImportCoordinator` here.
  /// - 39 → 40 in #2377 Phase 6 C4 (2026-08-26): App-owned `recordingOverlay`,
  ///   previously a local only. Idle-prewarm needs `applicationDidFinishLaunching()`
  ///   to reach the director after construction, and the approved plan
  ///   (`docs/feature-requests/issue-2377-2026-08-26-phase6-c4-idle-prewarm.md`
  ///   §3 step 4) places the app-lifetime overlay owner here rather than on
  ///   `AppLifecycleCoordinator`, which gains no overlay dependency.
  @Test func envWisprAppStoredPropertyCeilingHolds() throws {
    let body = try structBodyOfEnviousWisprApp()
    let count = countTopLevelStoredProperties(in: body)
    #expect(
      // #2455 C3 (#2460): 40 -> 41. `application`, the activation seam this type
      // needs for the onboarding-dismissal policy change. ONE property, not two:
      // the panel seam is consumed by collaborators and is passed through rather
      // than retained here.
      count <= 41,
      """
      EnviousWisprApp stored-property ceiling exceeded: \(count) > 41. \
      Raising the ceiling requires a Bible changelog entry. \
      New App-owned homes belong on EnviousWisprApp by design — this cap is \
      a thermostat: raise it deliberately, do not silently bump.
      """)
  }

  /// Non-private method ceiling. #919: the relocated composition root
  /// (`WisprBootstrapper`) exposes EXACTLY the front-door surface the thin
  /// `@main` shell needs — 4 lifecycle forwards (`applicationWillFinishLaunching`,
  /// `applicationDidFinishLaunching`, `applicationDidBecomeActive`,
  /// `applicationWillTerminate`) + 2 view factories (`mainWindowContent`,
  /// `onboardingWindowContent`) = 6 public `func`s. The 2 window-title
  /// accessors are computed `var`s (not counted). No DOMAIN methods are allowed
  /// beyond this front door — those belong on the individual homes. This cap is
  /// the public-surface gate from the #919 plan (= 8 public decls overall:
  /// these 6 funcs + the type + its `init`).
  @Test func envWisprAppNonPrivateMethodCeilingHolds() throws {
    let body = try structBodyOfEnviousWisprApp()
    let count = countTopLevelNonPrivateMethods(in: body)
    #expect(
      count <= 6,
      """
      WisprBootstrapper non-private method ceiling exceeded: \(count) > 6. \
      The bootstrapper's public surface is the 4 lifecycle forwards + 2 view \
      factories. New domain methods belong on the individual homes \
      (NavigationCoordinator, DictationRuntime, ...), not the composition root.
      """)
  }

  /// Allowed-imports ceiling.
  ///
  /// PR9 of #763 added EnviousWisprStorage to construct `TranscriptStore`
  /// directly in the composition root.
  ///
  /// PR-C.1 of #763 (#813) widened the allowlist to the full engine-module set
  /// (`EnviousWisprASR`, `EnviousWisprAudio`, `EnviousWisprLLM`,
  /// `EnviousWisprPipeline`). This is the deliberate consequence of making
  /// `EnviousWisprApp` the construction root: it now builds `AudioCaptureManager`,
  /// `ASRManagerProxy`, both pipelines,
  /// `LLMModelDiscoveryCoordinator`, etc. — the construction that used to live
  /// in the former root-state initializer. A composition root importing the modules it
  /// composes is correct; the anti-coupling intent is satisfied by the
  /// zero-non-private-method ceiling, which keeps the App struct construction-
  /// only with no behavior.
  @Test func envWisprAppImportsCeilingHolds() throws {
    let url = envWisprAppURL()
    let source = try String(contentsOf: url, encoding: .utf8)
    // #1348 Phase 3 added EnviousWisprModelDelivery: the composition root now
    // constructs the EG-1 delivery adapter over the shared controller (loads
    // the bundled delivery manifest, builds the DeliveryRegistration). A
    // composition root importing the leaf it composes is correct; the
    // anti-coupling intent is held by the zero-behavior ceiling.
    let allowed: Set<String> = [
      "SwiftUI", "EnviousWisprCore", "EnviousWisprServices", "EnviousWisprStorage",
      "EnviousWisprASR", "EnviousWisprAudio", "EnviousWisprLLM", "EnviousWisprPipeline",
      "EnviousWisprModelDelivery",
    ]
    let actual = parseImports(in: source)
    let unexpected = actual.subtracting(allowed)
    #expect(
      unexpected.isEmpty,
      """
      EnviousWisprApp imports outside allowlist: \(unexpected.sorted()). \
      Allowed: \(allowed.sorted()). Lower-tier modules belong on AppDelegate \
      or on specific @State home types, not on the composition root.
      """)
  }
}

private func envWisprAppURL() -> URL {
  // #919: the composition root moved out of the `@main` `EnviousWisprApp`
  // struct into `WisprBootstrapper` in EnviousWisprAppKit (so the unit-test
  // target links it without launching the app). This ceiling now tracks the
  // relocated root; the thin `@main` shell holds only 2 stored properties.
  RepoRoot.sourceURL("Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift")
}

private func structBodyOfEnviousWisprApp() throws -> String {
  let source = try String(contentsOf: envWisprAppURL(), encoding: .utf8)
  // #2455 C1: narrowed `public` -> `package`. The shell no longer names this
  // type at all — it reaches it through `LiveApplication` in EnviousWisprAppLive —
  // so nothing outside the package needs to see it.
  guard let openRange = source.range(of: "package final class WisprBootstrapper {") else {
    Issue.record("WisprBootstrapper declaration not found at expected path/shape")
    throw POSIXError(.ENOENT)
  }
  let openIdx = source.index(before: openRange.upperBound)  // points at '{'
  var depth = 0
  var idx = openIdx
  while idx < source.endIndex {
    let c = source[idx]
    if c == "{" { depth += 1 }
    if c == "}" {
      depth -= 1
      if depth == 0 { return String(source[source.index(after: openIdx)..<idx]) }
    }
    idx = source.index(after: idx)
  }
  Issue.record("EnviousWisprApp struct body has unbalanced braces")
  throw POSIXError(.EILSEQ)
}

/// Counts top-level (depth 0) `let` and `var` declarations on the App struct.
/// Stored properties include those marked with SwiftUI property wrappers
/// (`@State`, `@NSApplicationDelegateAdaptor`).
private func countTopLevelStoredProperties(in body: String) -> Int {
  RouterCeilingParser.storedPropertyCount(in: body)
}

/// Counts top-level non-private `func` declarations. The `body` computed
/// property is intentionally not a `func` and is excluded.
private func countTopLevelNonPrivateMethods(in body: String) -> Int {
  var depth = 0
  var count = 0
  for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
    let opens = line.filter { $0 == "{" }.count
    let closes = line.filter { $0 == "}" }.count
    let depthForThisLine = depth - max(0, closes - opens)
    if depthForThisLine == 0 {
      let s = String(line)
      if isNonPrivateMethodDeclaration(s) {
        count += 1
      }
    }
    depth += opens - closes
  }
  return count
}

private let nonPrivateMethodPattern: String =
  #"^[[:space:]]*(public|internal|package|open)?[[:space:]]*func[[:space:]]+[A-Za-z_]"#

private func isNonPrivateMethodDeclaration(_ line: String) -> Bool {
  guard line.range(of: nonPrivateMethodPattern, options: .regularExpression) != nil
  else { return false }
  // Reject if the line declares `private func` or `fileprivate func`.
  if line.range(
    of: #"^[[:space:]]*(private|fileprivate)[[:space:]]+func"#, options: .regularExpression)
    != nil
  {
    return false
  }
  return true
}

/// Parses `import <Module>` declarations at the top of the file (depth 0
/// outside any type body). Returns the module names.
private func parseImports(in source: String) -> Set<String> {
  var result: Set<String> = []
  let pattern = #"^[[:space:]]*import[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)"#
  let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
  let ns = source as NSString
  let range = NSRange(location: 0, length: ns.length)
  regex?.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
    guard let m = match, m.numberOfRanges > 1 else { return }
    result.insert(ns.substring(with: m.range(at: 1)))
  }
  return result
}
