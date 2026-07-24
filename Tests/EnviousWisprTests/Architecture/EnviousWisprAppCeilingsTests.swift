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
  @Test func envWisprAppStoredPropertyCeilingHolds() throws {
    let body = try structBodyOfEnviousWisprApp()
    let count = countTopLevelStoredProperties(in: body)
    #expect(
      count <= 39,
      """
      EnviousWisprApp stored-property ceiling exceeded: \(count) > 39. \
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

  /// Line-count trip-wire. Soft backstop against accidental file explosions;
  /// entanglement signals (stored properties, methods, imports) are the
  /// primary mechanical constraints. Ratcheted 250→270 in PR8 of epic #763
  /// (2026-05-19, #774) to absorb DictationRuntime construction (15 lines).
  /// Ratcheted 270→310 in PR9 of epic #763 (2026-05-19, #775) to absorb
  /// `DictationLifecycleCoordinator` construction (~25 lines: 11-collaborator
  /// init block + recordingLockedAccess struct literal + install() call +
  /// attachDictationLifecycleCoordinator call) and the hoisted
  /// `TranscriptStore` + `TranscriptCoordinator` construction (~3 lines).
  /// Ratcheted 310→340 in PR-B.2 of epic #763 (2026-05-19, #797) to absorb
  /// `AppWindowCoordinator` construction (~14 lines: two onboarding-guard
  /// closures), the `@State` declaration, the 9th `attach(...)` argument, the
  /// two `.environment(...)` injections, and the `ActionWirer` drain-before-
  /// auto-open rewrite. Soft trip-wire only — the stored-property cap is the
  /// primary entanglement signal.
  /// Ratcheted 340→370 in PR-B.3 of epic #763 (2026-05-20, #798) to absorb
  /// `MenuBarController` construction (~22 lines: five menu-action closures),
  /// the `@State` declaration, and the `_menuBarController` assignment. The
  /// `attach(...)` arg count is unchanged (drops two, adds one).
  /// Ratcheted 370→385 in PR-B.4 of epic #763 (2026-05-20, #799) to absorb
  /// `AppLifecycleCoordinator` construction (the seven-dependency `init` call)
  /// and its `@State` declaration + assignment, net of the `attach(...)` call
  /// collapsing from eight arguments to two. Cap set by the deterministic rule
  /// (post-change actual 375 + 10, rounded up to the nearest 5).
  /// Ratcheted 385→560 in PR-C.1 of epic #763 (2026-05-20, #813) to absorb the
  /// subsystem construction + init-time wiring relocated from the former root-state initializer
  /// (the composition root now constructs all 17 subsystems), the nine
  /// view-facing `@State` declarations + assignments, and the eighteen
  /// `.environment(...)` injections across the two Window scenes. Cap set by
  /// the deterministic rule (post-change actual 546 + 10, rounded up to the
  /// nearest 5). Line count is a soft 5x backstop — the stored-property and
  /// import ceilings are the primary entanglement signals.
  /// Ratcheted 560→580 in PR-C.3 of epic #763 (2026-05-20, #815) to absorb the
  /// `polishService` `@State` declaration + assignment and the
  /// `AppLifecycleCoordinator` init call expanding from one `appState:` argument
  /// to ten specific-home arguments. Cap set by the deterministic rule
  /// (post-change actual 569 + 10, rounded up to the nearest 5).
  /// Ratcheted 580→615 in #919 (2026-05-30): the composition root moved into
  /// `WisprBootstrapper` and absorbed the relocated `body` content as two view
  /// factories (`mainWindowContent`/`onboardingWindowContent`) + their private
  /// root views (`MainWindowRoot`/`OnboardingWindowRoot`) + the 4 lifecycle
  /// forwards, net of dropping the `@State` backing assignments. Cap set by the
  /// deterministic rule (post-change actual 604 + 10, rounded up to 615).
  /// Ratcheted 615→690 in #913 PR8 (2026-05-31, #832): the composition root
  /// absorbed the output-safety classifier holder + its off-heart-path prewarm
  /// method (load + publish + provider re-trigger). Cap set by the deterministic
  /// rule (post-change actual 679 + 10, rounded up to 690).
  /// Ratcheted 690→705 in #633 Phase 9 (2026-06-06): the composition root
  /// constructs `vocabularyPackManager`, passes it into `wireCustomWords`, and
  /// injects it into the main Window scene. Cap set by the deterministic rule
  /// (post-change actual 693 + 10, rounded up to nearest 5 = 705).
  /// Ratcheted 705→735 in #1019 (2026-06-09): the composition root constructs
  /// `updateTriggerCoordinator`, wires the dictation-active guard provider +
  /// launch start in `applicationWillFinishLaunching`, and tears the monitor
  /// down in `applicationWillTerminate`. Cap set by the deterministic rule
  /// (post-change actual 721 + 10, rounded up to nearest 5 = 735).
  /// Ratcheted 735→770 in #1063 PR2 (2026-06-20, crash-recovery replay): the
  /// composition root builds the per-orphan `RecoverySpoolReplayer` from existing
  /// app deps + the reshaped `RecoveryCoordinator` (replayer + dedup + contention
  /// closures), wires the "recovering" pill's Discard handler, and swaps the
  /// launch purge for `scanAndRecover`. No new App-owned stored property (the
  /// stored-property cap stays ≤ 30). Cap set by the deterministic rule
  /// (post-change actual 759 + 10, rounded up to nearest 5 = 770).
  /// Ratcheted 770→785 in #1029 (2026-06-21, eager notification tap routing): the
  /// composition root calls `updateCoordinator.activateNotificationTapRouting()` in
  /// `applicationWillFinishLaunching` so a tap on an already-delivered update
  /// notification (or a cold launch from it) routes even when the once-per-version
  /// guard suppresses a fresh post on rehydrate. Must live in the launch path (not
  /// `SparkleUpdateController.startUpdater()`, which tests exercise) to keep the
  /// notifier inert under unit tests. No new App-owned stored property. Cap set by
  /// the deterministic rule (post-change actual 774 + 10, rounded up to nearest 5 = 785).
  /// Ratcheted 785→845 in #1171 (2026-06-23, Telemetry Bible Phase 2): the
  /// composition root builds `EngineCoordinator` (its ~28-line injected
  /// `Dependencies`), wires the picker / recovery / driver-state pokes + the
  /// record-start ensure path, injects it into the main Window scene, and calls
  /// `start()`. Net of deleting the `onNeedsPreloadObservation` wiring + the
  /// `whisperKitSetup` settingsSync arg. Cap set by the deterministic rule
  /// (post-change actual 831 + 10, rounded up to nearest 5 = 845).
  /// Ratcheted 845→870 in #1173 (2026-06-23, Telemetry Bible Phase 4): the
  /// composition root builds the App-owned `SettingsChangeTelemetry` home (its
  /// `emitBaseline` closure constructs a `StandingSnapshotBuilder` for the
  /// onboarding-completion baseline), adds one fan-out branch (`handle(key)`)
  /// + its weak capture to the `settings.onChange` closure, and stores it. A
  /// narrow new App-owned home (+1 stored property, ≤ 31) keeping the funnel the
  /// single observation seam. Cap set by the deterministic rule (post-change
  /// actual 857 + 10, rounded up to nearest 5 = 870).
  /// Ratcheted 870→890 in #1176 (2026-06-24, Telemetry Bible Phase 7): the
  /// composition root constructs the `OnboardingProgress` session box (+1 stored
  /// property), threads it into `AppLifecycleCoordinator` (captured in the
  /// onboarding-dismiss closure for the window-close abandon) and `OnboardingV2View`,
  /// and emits the app-quit abandon in `applicationWillTerminate` before the
  /// Phase-1 flush. Cap set by the deterministic rule (post-change actual 876 + 10,
  /// rounded up to nearest 5 = 890).
  /// Ratcheted 890→905 in #1177 (2026-06-24, Telemetry Bible Phase 8a): the
  /// composition root injects the `.live` LLM-module telemetry sink into
  /// `KeychainManager` (Q3.3 + A6 seam) AND emits the Q3.1 output-safety classifier
  /// prewarm-failure telemetry (population event + Sentry handled error) from the
  /// App-layer `prewarmOutputClassifierIfNeeded` catch — its natural emit site. No
  /// new stored property; real wiring, not comment growth. Cap by the deterministic
  /// rule (post-change actual 902 + ~3, rounded up to nearest 5 = 905).
  /// Ratcheted 905→930 in #1271 (2026-07-02, EG-1 native integration): the
  /// composition root constructs `EGOneRuntime`, launch-starts it when the
  /// persisted provider is EG-1, threads it into both kernel-driver input
  /// structs + the crash-recovery replayer + `PipelineSettingsSync`
  /// (provider-change lifecycle), installs the telemetry bridge (mapping
  /// logic itself extracted to `EGOneTelemetryBridge` to keep the root
  /// thin), kills the child synchronously on terminate, and
  /// `.environment`-injects it — real wiring for the new App-owned home
  /// (see the 33→34 stored-property entry above). Cap by the deterministic
  /// rule (post-change actual 928 + ~2, rounded up to nearest 5 = 930).
  /// Ratcheted 930→945 in #1348 Phase 2 (2026-07-06): the composition root
  /// constructs `ModelDeliveryHome`, threads its Parakeet handle into the
  /// Parakeet driver inputs, stores + `.environment`-injects the home (see
  /// the 34→35 stored-property entry above) — real wiring for the owned
  /// model-delivery layer; all logic lives in the home/bridge, not here.
  /// Cap by the deterministic rule (post-change actual 943 + ~2, rounded up
  /// to nearest 5 = 945).
  /// Ratcheted 945→980 in #1348 Phase 3 (2026-07-06, EG-1 delivery
  /// convergence): the composition root now builds the EG-1 delivery adapter
  /// over the shared controller — loads the bundled EG-1 delivery manifest,
  /// constructs the `DeliveryRegistration` (install dir + metadata dir), wires
  /// `EGOneDeliveryAdapter`, seeds the first-run telemetry baseline, and
  /// injects the adapter into `EGOneRuntime` (construction-order fix so the
  /// adapter exists before launch activation). Real wiring for the converged
  /// limb; all logic lives in the adapter/runtime, not here. Cap by the
  /// deterministic rule (post-change actual 976 + ~2, rounded up to nearest
  /// 5 = 980).
  /// Ratcheted 980→995 in #1378 (2026-07-08): the composition root constructs
  /// `InputDevicePreferenceReconciler`, wires `AudioDeviceList.onDevicesChanged`,
  /// and performs the required launch-time reconcile after callback wiring.
  /// Policy remains outside the root. Cap by deterministic rule (actual 984
  /// + 10, rounded up to nearest 5 = 995).
  /// Ratcheted 995→1025 in #1480 (2026-07-11): the composition root builds the
  /// Bluetooth-awareness limb — a late-binding presenter holder, the
  /// `BluetoothAwarenessPresenter.live(...)` factory call, the injection into
  /// `AppLifecycleCoordinator`, and the settings.onChange reconcile hookup. The
  /// presenter's own wiring was extracted into `.live(...)` to keep the root lean;
  /// all decision logic lives on the presenter, not here. Cap by deterministic
  /// rule (actual 1018 + 7, rounded up to nearest 5 = 1025).
  /// Ratcheted 1025→1045 in #1386 PR-1 (2026-07-11): the composition root
  /// constructs `EGOneLegacyUpgradeCoordinator` over the existing adapter,
  /// wires its telemetry handler (attaching `selected_provider` here, where
  /// settings is in scope, so the coordinator stays provider-ignorant), and
  /// runs the one-time legacy launch table after the first-run baseline. All
  /// retirement logic lives on the coordinator, not here. Cap by deterministic
  /// rule (actual 1041 + ~2, rounded up to nearest 5 = 1045).
  /// Ratcheted 1045→1090 in #1452 (2026-07-11): `prewarmOutputClassifierIfNeeded`
  /// rewritten to call `holder.beginLoadIfNeeded` and execute the new
  /// `OutputClassifierEmissionPolicy.forOutcome` plan (dedupes the
  /// `output_classifier_load_failed` Sentry alert to at most once per process
  /// per disablement); the pure `OutputClassifierEmissionPolicy` struct is
  /// appended as a free-standing top-level type AFTER the class's closing
  /// brace, so it adds zero stored properties / methods to the composition
  /// root itself (stored-property and method ceilings above are unchanged) —
  /// only the file's physical line count grows. Cap by deterministic rule
  /// (actual 1088 + ~2, rounded up to nearest 5 = 1090).
  /// Ratcheted 1090→1120 in #1386 PR-2 (2026-07-16): the multilingual engine
  /// joins the owned delivery layer, so the root must name one more subsystem.
  /// What it names is deliberately small — this raise is what SURVIVED the
  /// ceiling's first verdict, not a request to skip it. The gate failed at 1204;
  /// the response was to move code to its right home, not to pick a bigger
  /// number: `WhisperKitDeliveryWiring` now owns the coordinator/backend/setup/
  /// projection construction, `ActiveEngineOperation.live` owns its own routing,
  /// `DiagnosticsCoordinator` owns the engine door its benchmark consumes (which
  /// also deleted an environment key), and `SetupCoordinator` owns the post-UI
  /// migration step (which kept `AppLifecycleCoordinator`'s allowlist intact).
  /// The residue is a handful of `let`s, two calls, and the `activeEngine`
  /// plumbing the stored-property entry above justifies: the irreducible cost of
  /// naming a subsystem. Cap by deterministic rule (actual 1117 + ~2, rounded up
  /// to nearest 5 = 1120). #1386 PR-2b re-applied the rule after the
  /// `whisperKitRetirement` ownership fix (stored-property entry above) added
  /// its declaration + assignment, then again after Codex 2b-r2 restored two
  /// behaviors the branch had accidentally deleted (the overlay position
  /// provider, #1583, and the recovery-success notice, #1464 — main's own
  /// lines returning home) and routed Discard through the active-engine door:
  /// actual 1128 + ~2, rounded up to nearest 5 = 1130. Third application
  /// (same PR, cloud review round 3): the engine-status closure handed to
  /// BackendMetadata added one line — actual 1131 + ~2, rounded to 1135.
  /// #1386 PR-2c: the two Remove seam assignments (the adapter unload hook,
  /// assignable only after the driver exists, and the dictation-in-flight
  /// authority for the refusal) — actual 1142 + ~2, rounded to 1145. Then the
  /// refusal grew its second authority (the minting gate, Codex 2c-r5 P2):
  /// actual 1146 + ~2, rounded to 1150. Then the founder's honest-pill ruling
  /// wired the install read into the press path (isSelectedModelInstalled):
  /// actual 1151 + ~2, rounded to 1155. Then that read became removal-aware
  /// (founder: a model mid-removal accepts no dictations; Codex 2c-r7 P1):
  /// actual 1160 + ~2, rounded to 1165. #1707 Phase 2 (recovery-v2
  /// transcription-engine retry): hoisted the WhisperKit backend construction
  /// earlier so `BatchDecodeFaultController` can be built from both backends,
  /// and threaded that controller into both `ParakeetInputs`/`WhisperKitInputs`
  /// and `AppLifecycleCoordinator`: actual 1187 + ~2, rounded to 1190. Then
  /// Codex r6 required gating the controller's own construction behind
  /// `#if DEBUG` (a Release build must not wire real fault-injection
  /// machinery into its object graph): actual 1200 + ~2, rounded to 1205.
  /// #1707 Phase 3 (crash-safety-net readiness gating): 1205 → 1315 for the
  /// `EngineRecoveryGate` construction + the composition-root wiring pass
  /// that injects its closures downward into every guarded engine-mutating
  /// call site (`kernelDriver`/`whisperKitKernelDriver`, `asrManager`'s
  /// concrete type, `whisperKitSetup`, `whisperKitRetirement`,
  /// `modelDelivery`, `diagnosticsCoordinator.benchmark`) plus
  /// `EngineCoordinator`'s three new `Dependencies` fields and
  /// `RecoveryCoordinator`'s claim closures. This is the irreducible cost of
  /// naming a new cross-cutting subsystem, the same class of residue
  /// `activeEngine`/`whisperKitRetirement` already justify above — only the
  /// composition root has every guarded object in scope simultaneously to
  /// wire them together; no domain logic moved here (the gate itself and
  /// every guard's behavior live on their own types). Cap by deterministic
  /// rule (actual 1309 + ~2, rounded up to nearest 5 = 1315).
  /// #1732 (GitHub cloud review round 9): 1315 → 1330 for the
  /// `engineCoordinatorForRecoveryGate` weak local var + its wiring into
  /// `isDictationActive`, closing a narrow race where a record-press still
  /// mid-`beginMinting()` (not yet an active kernel session) could have its
  /// engine reclaimed by the next recovery item. Same class of irreducible
  /// composition-root residue as the entries above; no domain logic moved
  /// here. Cap by deterministic rule (actual 1326 + ~2, rounded up to
  /// nearest 5 = 1330).
  @Test func envWisprAppLineCountCeilingHolds() throws {
    let url = envWisprAppURL()
    let source = try String(contentsOf: url, encoding: .utf8)
    let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      lineCount <= 1330,
      """
      WisprBootstrapper line count exceeded: \(lineCount) > 1330. \
      Raising the ceiling requires a Bible changelog entry.
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
  guard let openRange = source.range(of: "public final class WisprBootstrapper {") else {
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
  var depth = 0
  var count = 0
  for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
    let opens = line.filter { $0 == "{" }.count
    let closes = line.filter { $0 == "}" }.count
    let depthForThisLine = depth - max(0, closes - opens)
    if depthForThisLine == 0 {
      let s = String(line)
      if isStoredPropertyDeclaration(s) {
        count += 1
      }
    }
    depth += opens - closes
  }
  return count
}

private let storedPropertyPattern: String = {
  // Match `let|var <ident>` at the top level, allowing property wrappers
  // (with optional parenthesized args) and access modifiers in any order
  // before the declaration keyword.
  let attrs = #"(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*"#
  let access = #"(public|internal|private|fileprivate|package|open)?"#
  return "^[[:space:]]*\(attrs)\(access)[[:space:]]*(let|var)[[:space:]]+[A-Za-z_]"
}()

private func isStoredPropertyDeclaration(_ line: String) -> Bool {
  guard line.range(of: storedPropertyPattern, options: .regularExpression) != nil
  else { return false }
  // Exclude computed properties — these have an opening `{` on the same line
  // as the declaration (e.g. `var body: some Scene {`). Stored properties
  // never have a trailing `{` on the declaration line.
  if line.range(of: #"\{[[:space:]]*$"#, options: .regularExpression) != nil {
    return false
  }
  return true
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
