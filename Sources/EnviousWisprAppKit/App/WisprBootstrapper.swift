import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLivePreview
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import SwiftUI

/// #919: the single production composition root, relocated out of the `@main`
/// `EnviousWisprApp` struct into `EnviousWisprAppKit` so the unit-test target
/// can link this code WITHOUT launching the app. The thin `EnviousWisprApp`
/// shell (still `@main`, still owning the `@NSApplicationDelegateAdaptor` and
/// app identity) constructs ONE of these in `App.init()`, attaches it to the
/// shell `AppDelegate`, and shows `mainWindowContent()` / `onboardingWindowContent()`.
/// App-owned homes stay `internal` to this module (no public leak); only the
/// bootstrapper type + its init + 4 lifecycle methods + 2 view factories + 2
/// window-title accessors cross to the shell.
@MainActor
package final class WisprBootstrapper {
  // App-owned homes (epic #763 composition root). Held as `let` on this
  // bootstrapper (which the shell keeps alive via a single `@State`); injected
  // into views via `.environment(...)` inside the view factories below.
  let navigationCoordinator: NavigationCoordinator
  let diagnosticsCoordinator: DiagnosticsCoordinator
  /// Owns the crash-recovery limb: arms each recording's encrypted spool,
  /// deletes it on durable save, and on launch scans for orphan spools and
  /// replays them (#1063 PR2 — replaces PR1's launch purge).
  let recoveryCoordinator: RecoveryCoordinator
  let languageSuggestionPresenter: LanguageSuggestionPresenter
  let updateCoordinatorHolder: UpdateCoordinatorHolder
  /// #3545: injected into the main window for the Settings search arrival's key watcher.
  let settingsKeyMonitor: any SettingsKeyMonitoring
  let sparkleUpdateController: SparkleUpdateController
  let updateTriggerCoordinator: UpdateTriggerCoordinator
  let transcriptCoordinator: TranscriptCoordinator
  /// #3972 — EnviousMeet's one owner of meetings: recording, the processing queue, recovery,
  /// deletion and quit.
  let meetingCoordinator: MeetingCoordinator
  /// #3972 C5: the one route to a meeting Start, shared by the EnviousMeet page and the menu bar.
  let meetingStartFlow: MeetingStartFlow
  /// #4017: EnviousMeet's setup visit, kept for the app run so leaving the page keeps the place.
  let meetingOnboardingModel: MeetingOnboardingModel
  /// #4012: notices calls and asks to record them.
  let callDetection: CallDetectionCoordinator
  let meetingMemoryPressure: MeetingMemoryPressure
  /// #2648 — Transcribe a File's state machine, held here so the run survives
  /// the page being closed.
  let fileImportCoordinator: FileImportCoordinator
  #if DEBUG
    /// #2885 — the DEBUG-only door through which Live UAT hands a file to
    /// `fileImportCoordinator` without the screen. Installed after launch, removed at quit.
    let debugImportDoor: DebugImportDoor
    /// #3765 — the DEBUG-only Unix-socket door through which scripts read and change app
    /// state through the owners below. Installed after launch, closed first at quit.
    let devControlDoor: DevControlDoor
    /// The launch-time install, kept so quit can cancel it; `uninstall()` is what stops a
    /// listener, before or while it starts.
    private var devControlInstall: Task<Void, Never>?
  #endif
  let liveRecordingState: LiveRecordingState
  let lastRecordingResult: LastRecordingResult
  let backendMetadata: BackendMetadata
  /// #1171 — the sole owner of ASR-engine selection, status, and switching.
  let engineCoordinator: EngineCoordinator
  let dictationRuntime: DictationRuntime
  let hotkeyService: HotkeyService
  let appWindowCoordinator: AppWindowCoordinator
  /// #4101: the one record of the app the user came from; started by `appLifecycleCoordinator`,
  /// read by History Paste through the main window's environment.
  let previousApplicationTracker: PreviousApplicationTracker
  /// #4101: History's Paste, one instance, so both details and the main window share the one
  /// paste that may be waiting.
  let historyPaste: HistoryPaste
  let menuBarController: MenuBarController
  let appLifecycleCoordinator: AppLifecycleCoordinator

  // The nine view-facing subsystems (epic #763), injected into both Window
  // scenes' environment by the view factories.
  let settings: SettingsManager
  let permissions: PermissionsService
  /// #1176: in-flight onboarding session, read at app-quit to emit abandon.
  let onboardingProgress = OnboardingProgress()
  let asrManager: any ASRManagerInterface
  /// #1386 PR-2: the one door to whichever engine is active. Shared plumbing —
  /// crash recovery (constructed here) and the Diagnostics benchmark (via the
  /// environment) both need the SAME routing, and `DiagnosticsCoordinator` is
  /// capped at its single benchmark collaborator by design.
  let activeEngine: ActiveEngineOperation
  let customWordsCoordinator: CustomWordsCoordinator
  let snippetsCoordinator: SnippetsCoordinator
  let contactsImportCoordinator: ContactsImportCoordinator
  /// #1701 Chunk 2 — UI Cancel routes through `customWordsCoordinator.cancelBulkImportEnrichment`.
  let bulkImportEnrichmentCoordinator: BulkImportEnrichmentCoordinator
  let setup: SetupCoordinator
  /// #1271 — EG-1 native runtime home (model store + inference server).
  /// #2649: both local engines, named. See `LocalPolishRuntimeSet`.
  ///
  /// This REPLACED a separate `egOneRuntime` property rather than joining it.
  /// The set already holds that runtime, so keeping both properties would
  /// retain the same runtime twice.
  let localPolishRuntimes: LocalPolishRuntimeSet
  /// #1348 Phase 2: owned model-delivery home (controller + Parakeet
  /// registration + telemetry bridge + observable UI mirror). The +1 stored
  /// property is the plan's named cost.
  let modelDelivery: ModelDeliveryHome
  /// The take selector also answers the Dictionary status line.
  let checkerEligibility: LearnedWordCheckerEligibility

  /// #1386 PR-2; #3735: the Whisper model migration. Stored because nothing else owns it: it
  /// is reached only through closures (`SetupCoordinator` calls one once) that capture it
  /// weakly, and a closure capture cannot keep it alive. Held here, it lives as long as the
  /// app — which is what "runs on every launch" requires.
  let whisperMigration: WhisperModelMigration
  let audioDeviceList: AudioDeviceList
  /// #2376 C7: the Appearance page's window onto the recording pill. A
  /// view-facing home like the nine beside it, injected into every window root
  /// that hosts Settings.
  let pillAppearance: PillAppearanceModel
  let inputDevicePreferenceReconciler: InputDevicePreferenceReconciler
  let aiAvailability: AIAvailabilityCoordinator
  let keychainManager: KeychainManager
  let llmDiscovery: LLMModelDiscoveryCoordinator
  /// #3438: the AI polish setup warnings as ONE slot (the `learnFromEdits` shape): which cloud
  /// keys are saved, and which warnings may show.
  let polishSetup: PolishSetupWiring
  let vocabularyPackManager: VocabularyPackManager

  /// Quick Add (#2381), as ONE slot rather than four.
  ///
  /// The coordinator, the panel host and the Services provider all live inside it. That is the
  /// documented way to spend one stored-property slot on a group of collaborators here, and it is
  /// what keeps the feature's deletability honest: removing Quick Add is three directories, this
  /// property, and the one `install()` call below.
  let quickAdd: QuickAddWiring

  /// App-owned output-safety classifier holder (#832/#913 PR8). The classifier
  /// is loaded asynchronously off the heart path at prewarm; the holder lets the
  /// live-dictation `LLMPolishStep`s pick it up once ready.
  let outputClassifierHolder: OutputClassifierHolder

  /// Telemetry Bible Phase 4 (#1173). Observes the settings funnel for coalesced
  /// `settings.changed` deltas + the onboarding-completion baseline. Held
  /// app-lifetime (a weak-only hold would dealloc and silently stop emitting).
  let settingsChangeTelemetry: SettingsChangeTelemetry

  /// #2377 Phase 6 C4: the app-lifetime overlay owner, previously a local
  /// only. Storing it here is what lets `applicationDidFinishLaunching()`
  /// call `recordingOverlay.prewarmFirstRender()` — the +1 stored property
  /// is the plan's named cost.
  let recordingOverlay: OverlayDirector
  #if DEBUG
    /// #3736: plays sample pills through `recordingOverlay` for Settings > Diagnostics > Pill
    /// Preview. Absent from Release.
    let pillPreviewController: PillPreviewController
  #endif

  /// #996: Self-Learning Dictionary as ONE app-lifetime slot (the Quick Add
  /// shape). The learned correction coordinator, the Undo-pill presenter, the
  /// paste observer, the watcher and the arm selection live inside it; the
  /// coordinator and the paste registry hold their collaborators weakly, so
  /// this property is what keeps the feature alive for the app's lifetime.
  let learnFromEdits: LearnFromEditsWiring

  /// - Parameter makeHotkeyEffects: supplies the live desktop-effect adapter the
  ///   one shared `HotkeyService` will use.
  ///
  /// **Required and non-defaulted, which is the point (#2455 C1).** A default here
  /// would let this module assemble a production root on its own and would make
  /// `EnviousWisprAppLive` a passive forwarder — the shape grounded review r2
  /// rejected in advance. With no default, every caller must state its choice, and
  /// AppLive is the only production-choice site.
  ///
  /// C2 (#2459) made what AppLive passes here a live adapter from
  /// `EnviousWisprDesktopEffects`, which `EnviousWisprTests` may not import —
  /// enforced by `scripts/check-dependency-direction.sh`, not by the module graph,
  /// which does not enforce itself under Xcode. The seam does not move.
  /// #2455 C3: this type's own activation seam, for the onboarding-dismissal
  /// policy change in the scene body below.
  ///
  /// One stored property, not two: the panel seam is consumed by collaborators
  /// rather than by this type, so only the activator is retained.
  ///
  /// `fileprivate`, not `private`: `ActionWirer` below is a separate type in this
  /// file and is handed this seam at construction. Swift's `private` does not reach
  /// across type boundaries even within one file. Still unreachable from anywhere
  /// else, which is what the C3 seam is for.
  fileprivate let application: any ApplicationActivating

  /// - Parameter presentationEffects: the activation and panel-presentation seams
  ///   (#2455 C3). Required and non-defaulted for the same reason
  ///   `makeHotkeyEffects` is: a default would let this module assemble a
  ///   production root that reaches the real desktop, which is precisely what
  ///   `EnviousWisprTests` links.
  package init(
    makeHotkeyEffects: () -> any DesktopHotkeyEffects,
    presentationEffects: DesktopPresentationEffects,
    // #3062: the live scroll-wheel monitor seam. Required and non-defaulted for
    // the same reason `makeHotkeyEffects` is: a default would let this
    // test-linked module install a monitor on the developer's desktop.
    scrollWheelMonitor: any ScrollWheelMonitoring,
    // #3545: the Settings search arrival's key watcher. Required and non-defaulted for the same
    // reason as `scrollWheelMonitor`.
    settingsKeyMonitor: any SettingsKeyMonitoring,
    relocationRelauncher: any RelocationRelaunching,
    overlayEffects: DesktopOverlayEffects,
    // #1413: the output-volume and media-player seams. Required and non-defaulted
    // for the same reason `makeHotkeyEffects` is: a default would let this
    // test-linked module lower the developer's speakers or pause their Spotify.
    otherAudioEffects: OtherAudioEffects
  ) {
    self.application = presentationEffects.application
    // ===== Subsystem construction (epic #763) =====
    // `EnviousWisprApp` is the composition root: every subsystem is constructed
    // here. Construction order is load-bearing: `pasteCompletionRegistry` before
    // the pipelines (they receive it); `settingsSync` after both pipelines +
    // `setup`.

    // #923: one-time dev→shared settings migration; MUST precede SettingsManager()
    // (mutates the store it reads). Release/shipped builds no-op. See migration doc.
    SettingsDefaultsMigration.migrateIfNeeded()
    let settings = SettingsManager()
    // #1047: apply the persisted appearance before any window is built so a
    // pinned Dark never flashes white. `.system` clears the override (follow OS).
    AppearanceController.apply(settings.appearancePreference)
    let permissions = PermissionsService()
    // #1177 (Telemetry Bible Phase 8): inject the live LLM-module telemetry sink at the
    // composition root. This is the ONLY KeychainManager that gets `.live`; it carries
    // the sink for the legacy-key-cleanup (Q3.3) + cloud-prewarm (A6) quiet limbs.
    let keychainManager = KeychainManager(telemetrySink: .live)
    // **The host is built early and the DIRECTOR is not** (#2292 C2).
    //
    // `OverlayWindowHost.init` registers an active-Space observer and nothing
    // else — no panel exists until the first `present` — so it costs nothing to
    // sit here, and moving it would buy nothing.
    //
    // The director moved DOWN, to just after the Live Preview installation
    // below. It needs that installation's bridge at construction, and the
    // installer needs `audioCapture` and `settingsSync`, both of which are built
    // further down this function. `PipelineSettingsSync` is downstream of both
    // ASR pipelines, so hoisting the installer would mean hoisting those — the
    // move that does work is this one.
    let overlayHost = OverlayWindowHost(effects: overlayEffects)
    let audioDeviceList = AudioDeviceList()
    let inputDevicePreferenceReconciler = InputDevicePreferenceReconciler(settings: settings)
    audioDeviceList.onDevicesChanged = { [weak inputDevicePreferenceReconciler] devices in
      inputDevicePreferenceReconciler?.reconcile(availableDevices: devices)
    }
    inputDevicePreferenceReconciler.reconcile(
      availableDevices: audioDeviceList.availableInputDevices)
    let captureTelemetry = CaptureTelemetryState()
    let customWordsCoordinator = CustomWordsCoordinator()
    let snippetsCoordinator = SnippetsCoordinator()
    // #636: contacts-import orchestrator (opt-in import + bulk-remove + background
    // alias enrichment via the reused on-device suggester). #636 follow-up.
    let contactsImportCoordinator = ContactsImportCoordinator(
      customWords: customWordsCoordinator,
      aliasSuggester: customWordsCoordinator.aliasSuggester)
    let customWordsPropagator = CustomWordsPropagator()
    // #633 Phase 9: owns enabled vocabulary-pack state; merges pack terms into
    // the corrector lane (default OFF). Wired into `wireCustomWords` below.
    let vocabularyPackManager = VocabularyPackManager()
    // #3897: automatic repair of a stale report runs only while its readers can show it:
    // dictation's provider is Apple Intelligence, or onboarding (whose card reads it) is open.
    let aiAvailability = AIAvailabilityCoordinator(
      repairDependencies: AppleAvailabilityRepairDependencies(
        isRepairEligible: { [settings] in
          AppleAvailabilityRepair.isEligible(
            provider: settings.llmProvider,
            onboardingComplete: settings.onboardingState == .completed)
        }))

    // Audio capture runs in-process (#1543, D-028 — the separate XPC audio
    // helper was collapsed away). The ASR helper below stays isolated.
    //
    // #1807 (§C): kept as a separate, concretely-typed reference so its
    // `onRecoveryWriterQuiescent` closure can be wired to `recoveryCoordinator`
    // once that exists below — the closure lives on the concrete type, not
    // the `AudioCaptureInterface` protocol, so every other conformer (test
    // fakes, simulator doubles) needs no change.
    let audioCaptureManager = AudioCaptureManager()
    let audioCapture: any AudioCaptureInterface = InputResolutionTelemetryReporting.observing(
      audioCaptureManager)

    // #1707 Phase 3 (§3.2): the atomic mutual-exclusion primitive between
    // crash-recovery replay and every OTHER engine-mutating operation. One
    // instance per app session, injected downward as closures into every
    // guarded call site below — never referenced by concrete type outside
    // `EnviousWisprAppKit` (the composition root is the only place both
    // this AppKit-level type and the lower-module call sites are in scope
    // together).
    // #1741 Chunk 3 — moved before `asrManager` (was constructed 10 lines
    // below it): `asrManager`'s new required `engineMutationScope` argument
    // needs the gate, and the one shared capability value below, to already
    // exist.
    let engineRecoveryGate = EngineRecoveryGate()
    // #2648 — the ONE claim on the shared ASR-and-polish resource, built here
    // beside `engineRecoveryGate` because it is the same kind of thing: an
    // arbitration authority the composition root owns and hands downward as
    // narrow closures, so no lower module imports upward to reach it.
    //
    // It is NOT the same authority. `engineRecoveryGate` keeps crash recovery
    // away from engine MUTATION and deliberately admits several mutations at
    // once; this admits exactly one WORKLOAD — a dictation, a replay, or (from
    // #2648's later chunks) a file import — onto EG-1's single inference slot.
    let engineLease = EngineLease()
    // #3972 C4a: EnviousMeet's wake signal. Built this early because the lease release and the
    // engine switch below poke it (#4052: a final pass waits on both).
    let meetingWakes = MeetingWakeSignal()
    // #1741 Chunk 3 — forward reference for the shared scope's wake closure;
    // `recoveryCoordinator` isn't constructed until much later in this
    // function. Matches the existing `engineCoordinatorForRecoveryGate`
    // forward-declared-then-assigned-after-construction pattern below.
    weak var recoveryCoordinatorForEngineMutationScope: RecoveryCoordinator?
    // #2648, cloud review — the same forward-declared-then-assigned pattern, for
    // the same reason: the engine-switch gate and the local-polisher pin are
    // both constructed long before the import coordinator exists, and both have
    // to be able to see a running import.
    weak var fileImportCoordinatorForGates: FileImportCoordinator?
    // #3853: same pattern; the import's frozen polish provider lives on the runner.
    weak var fileImportRunnerForGates: FileImportRunner?
    // GitHub cloud review, PR #1732: captured by `isDictationActive` below,
    // assigned once `engineCoordinator` exists. (#3546 A3: declared here, ahead of the
    // Diagnostics speed test, which also reads its switch gate.) A record
    // press that has called `beginMinting()` but not yet reached an active
    // kernel session (still suspended in `preWarm`/the recovery-arm await)
    // does not make `liveRecordingState.isDictationActive` true — without
    // this, recovery's per-item scan could reclaim the engine for the next
    // orphan during exactly that window, and the in-flight press would
    // abort when its own stale-gate re-check catches up.
    // `weak`, matching every other cross-reference between these two
    // coordinators in this file — avoids a retain cycle.
    weak var engineCoordinatorForRecoveryGate: EngineCoordinator?
    // #1741 — the ONE shared mutation-side capability (§3 construction-
    // topology correction: one value, not one per consumer), threaded through
    // each consumer's required initializer argument as this plan migrates it
    // off the old defaulted-closure-triplet shape, one type at a time across
    // several chunks. A consumer not yet migrated stays on its existing
    // per-consumer closure wiring below until its own chunk lands.
    let engineMutationScope = EngineMutationScope.live(
      // #2787: no warm-up, unload, download or migration while an abandoned
      // vendor decode still owns the engine — the hold is the one holder the
      // recovery gate cannot see, because it is not a recovery.
      tryBegin: { [engineRecoveryGate, engineLease] in
        guard engineLease.currentHolder != .abandonedDecode else { return false }
        return engineRecoveryGate.tryBeginMutation()
      },
      end: { [engineRecoveryGate] in engineRecoveryGate.endMutation() },
      wake: { recoveryCoordinatorForEngineMutationScope?.requestRecoveryRecheck() },
      onRefused: { site in TelemetryService.shared.recoveryEngineActionDeferred(site: site) })

    // #1908: ASR now always runs in-process, same as Whisper — the XPC
    // helper this used to conditionally route to (`ASRManagerProxy` /
    // `EnviousWisprASRService`) is deleted; macOS can no longer reclaim it
    // out from under an idle dictation. The `useXPCASRService` selector and
    // its `defaults write` escape hatch are retired along with it.
    // #3546: ONE Parakeet load-request provider, handed to the manager here and
    // to the Parakeet adapter through `ParakeetInputs` below, so every load
    // reads the request the adapter's warm-up wrote.
    let parakeetSelection = ParakeetSelectionProvider()
    // #3972: kept concrete as well, for EnviousMeet's offline-mode admission.
    let concreteASRManager = ASRManager(
      engineMutationScope: engineMutationScope, parakeetSelection: parakeetSelection)
    let asrManager: any ASRManagerInterface = concreteASRManager
    // #3972 C4a: EnviousMeet's one coordinator is built after the dictation runtime; owners
    // built before it (the engine switch, the output hold) read it through this box.
    let meetingBox = MeetingCoordinatorBox()
    // #2787: owns the engine AFTER a session ends with its decode still running.
    let abandonedDecodeHold = AbandonedDecodeHold(
      lease: engineLease, occupancy: asrManager.vendorDecodeOccupancy)
    // #2787: the persisted per-take stage checkpoint (see `TranscriptionCheckpointStore`).
    let transcriptionCheckpointStore = TranscriptionCheckpointStore()
    let transcriptionCheckpoint: @MainActor (TranscriptionCheckpointEvent) -> Void = {
      [transcriptionCheckpointStore] event in transcriptionCheckpointStore.apply(event)
    }

    let savedKeyPresence = SavedKeyPresence()
    let llmDiscovery = LLMModelDiscoveryCoordinator(
      keychainManager: keychainManager, savedKeyPresence: savedKeyPresence)

    let transcriptStore = TranscriptStore()
    // The History half of #2811's turn-label telemetry; the wizard half is wired on
    // `FileImportCoordinator` below, and both emit the same shape-only events.
    let transcriptCoordinator = TranscriptCoordinator(
      store: transcriptStore,
      emitRenameTelemetry: { outcome in
        TelemetryService.shared.trackFileImportRename(outcome: outcome)
      },
      emitTurnsDisplayedTelemetry: {
        TelemetryService.shared.trackFileImportTurnsDisplayed(screen: .history)
      })

    // #832/#913 PR8: app-owned output-safety classifier holder. Created before
    // the polish service + both kernel drivers so all three receive the same
    // instance; the classifier itself loads asynchronously at prewarm (below).
    let outputClassifierHolder = OutputClassifierHolder()

    // Phase 0 (#640) — single shared paste-completion registry, owned by the
    // composition root and injected into both kernel drivers' instances of
    // `KernelFinalizationWiring` (and any future #629 auto-learn subscriber).
    // One instance per app session; constructed before both drivers so they
    // share the same registry. (#1106 re-homed this from the deleted re-polish
    // service per `state-ownership.md` shared-infra-homes-not-feature-services.)
    let pasteCompletionRegistry = PasteCompletionRegistry()

    // #1348 Phase 2/3 — owned model delivery. Constructed BEFORE EG-1 so the
    // EG-1 adapter receives the ONE shared `ModelDeliveryController` (#1348
    // §Decision A construction-order fix: the adapter must exist before launch
    // activation calls it). A failed bundled-manifest load leaves the Parakeet
    // handle nil (legacy path), unit-tested can't-happen.
    // #1741 Chunk 6 — `.main` is the ONLY production value: the signed app's
    // own bundle stays the manifest trust root (contract §4a), unchanged.
    let modelDelivery = ModelDeliveryHome(
      engineMutationScope: engineMutationScope, manifestBundle: .main)
    // #3546: the one Parakeet selection-policy owner, sharing the request
    // provider `asrManager` was built with above.
    let parakeetUpgrade = modelDelivery.installParakeetUpgrade(
      parakeetSelection: parakeetSelection,
      isOnboardingComplete: { [weak settings] in settings?.onboardingState == .completed })
    // Usability counts a ready serving Parakeet model, not just its request.
    parakeetUpgrade.servingReadiness = { [asrManager] in
      asrManager.activeBackendType == .parakeet && asrManager.isModelLoaded
    }

    // #1707 Phase 2: `whisperBackend` is hoisted here (only these two
    // lines — NOT the full `whisperKernelDriver`, which still needs
    // `vadSource`/`languageDetector` built later) so `BatchDecodeFaultController`
    // can be constructed with BOTH backend references before the Parakeet
    // driver below. No circular dependency: `WhisperDeliveryWiring.make`'s
    // inputs are already in scope. #3735: the backend is transcribe.cpp.
    let whisper = WhisperDeliveryWiring.make(
      modelDelivery: modelDelivery, settings: settings, engineMutationScope: engineMutationScope)
    let whisperBackend = whisper.backend

    // #1707 Phase 2: DEBUG fault-injection oracle (§11.1/§3.2a-i) — the SOLE
    // owner of every batch-decode fault command, dispatching to whichever
    // backend-specific mechanism it holds a reference to. #1908: passes the
    // `ASRManagerInterface` existential directly rather than downcasting to
    // the (now-deleted) concrete `ASRManagerProxy` type — that downcast is
    // exactly what went silently dark when the composition root stopped
    // constructing it.
    //
    // Codex r6: the CONTROLLER TYPE is deliberately not `#if DEBUG`-gated
    // (only its real-engine-boundary methods are, § the type's own header
    // comment), but that does not mean it should exist in a Release build's
    // OBJECT GRAPH — every real decode call consults its adapter-boundary
    // `shouldForceFailBatchDecode`, which now also records an ever-growing,
    // never-cleared attempt-identity list. Construct a real instance only in
    // DEBUG; Release wires `nil`, exactly like production already does for
    // every other DEBUG-only fault seam.
    #if DEBUG
      let batchDecodeFaultController: BatchDecodeFaultController? = BatchDecodeFaultController(
        whisperBackend: whisperBackend,
        asrManager: asrManager)
    #else
      let batchDecodeFaultController: BatchDecodeFaultController? = nil
    #endif
    // #3735: the DEBUG `whisper_memory_pressure` fault command runs the backend's real
    // pressure handler (authorized idle unload), never a simulated one.
    #if DEBUG
      let whisperMemoryPressure: (@MainActor () async -> Bool)? = { [whisperBackend] in
        await whisperBackend.handleMemoryPressure()
        return await whisperBackend.isReady
      }
    #else
      let whisperMemoryPressure: (@MainActor () async -> Bool)? = nil
    #endif

    // #1271/#1348 Phase 3 — EG-1 native runtime: the model bytes now move
    // through the shared delivery engine via `EGOneDeliveryAdapter` (a limb —
    // a delivery failure degrades polish to raw text, never blocks dictation).
    // Shared-infra home, threaded into both kernel drivers + crash recovery.
    // Launch-start below so dictation never depends on settings opening;
    // `isActiveProvider` is a LIVE read (r2). The runtime keeps the EGOne
    // manifest (contextTokens / promptFamily / activation blockers); the
    // adapter owns the delivery manifest (fetch/install/content identity).
    //
    // #1386 PR-1 rev2: retire the one shipped EG-1 monolith. The coordinator
    // recognizes it by exact size + digest, records the owed replacement,
    // deletes it, and asks the adapter for the normal download; fresh
    // installs land in the owned `Models/eg-1` home.
    let egOneManifest = try? EGOneManifest.loadBundled()
    let egOneServerBinaryURL = Bundle.main.url(forResource: "llama-server", withExtension: nil)
    let egOneAppSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    var egOneAdapter: EGOneDeliveryAdapter?
    var egOneUpgrade: (registration: DeliveryRegistration, coordinator: EGOneUpgradeCoordinator)?
    if let deliveryManifest = try? DeliveryManifest.loadBundled(resource: "eg1-delivery-manifest") {
      let registration = DeliveryRegistration(
        manifest: deliveryManifest,
        installDirectory: egOneAppSupport.appendingPathComponent(
          "EnviousWispr/Models/eg-1", isDirectory: true),
        metadataDirectory: egOneAppSupport.appendingPathComponent(
          "EnviousWispr/ModelDelivery", isDirectory: true))
      let adapter = EGOneDeliveryAdapter(
        controller: modelDelivery.controller,
        registration: registration,
        version: egOneManifest?.resolvedDisplayVersion)  // #2109: label, not revision
      egOneAdapter = adapter

      let coordinator = EGOneUpgradeCoordinator(
        adapter: adapter,
        appSupportDirectory: egOneAppSupport,
        identity: deliveryManifest.identity,
        installDirectory: registration.installDirectory,
        isOnboardingComplete: { [weak settings] in settings?.onboardingState == .completed })
      // `selected_provider` attaches here (settings in scope); coordinator
      // stays provider-ignorant.
      coordinator.onEvent = EGOneTelemetryBridge.upgradeHandler(
        selectedProvider: { [weak settings] in settings?.llmProvider == .egOne })
      egOneUpgrade = (registration, coordinator)
    }
    #if DEBUG
      let debugScriptedChecker = LearnedWordCheckUATDoor.configuration()
      let debugLearnedWordAdapter =
        debugScriptedChecker == nil
        ? LearnedWordCheckAdapterDoor.configuration(.egOne) : nil
      let debugS1LearnedWordAdapter =
        debugScriptedChecker == nil
        ? LearnedWordCheckAdapterDoor.configuration(.s1Mini) : nil
    #else
      let debugScriptedChecker: (any LearnedWordChecking)? = nil
      let debugLearnedWordAdapter: (url: URL, threshold: Double)? = nil
      let debugS1LearnedWordAdapter: (url: URL, threshold: Double)? = nil
    #endif
    let learnedWordAdapterProvider: @MainActor () async -> URL? = {
      if let debugLearnedWordAdapter { return debugLearnedWordAdapter.url }
      guard let base = egOneUpgrade?.registration,
        let promptTemplateID = egOneManifest?.promptTemplateID
      else { return nil }
      return await modelDelivery.admittedCompatibleCheckerURL(
        engine: .egOne, baseRegistration: base, promptTemplateID: promptTemplateID)
    }
    let egOneRuntime = EGOneRuntime(
      manifest: egOneManifest, serverBinaryURL: egOneServerBinaryURL, delivery: egOneAdapter,
      learnedWordAdapterProvider: learnedWordAdapterProvider)
    egOneRuntime.isActiveProvider = { [weak settings] in settings?.llmProvider == .egOne }
    egOneRuntime.onEvent = EGOneTelemetryBridge.handler(engine: .egOne)
    if let egOneUpgrade {
      // First-run baseline (#1348 §16.2) → legacy launch table → the RUNTIME
      // decides if the completed replacement boots the server (PR #1500 P1).
      let delivery = modelDelivery
      Task {
        await delivery.controller.sweepSupersededStaging(egOneUpgrade.registration)  // #2119
        await delivery.recordFirstRunBaseline(for: egOneUpgrade.registration)
        await egOneUpgrade.coordinator.runLaunch()
        egOneRuntime.activateAfterAutomaticReplacementIfNeeded()
        // #3105: the word check follows the installed base, selected or not.
        if let prompt = egOneManifest?.promptTemplateID {
          _ = await delivery.ensureCheckerAdapter(
            engine: .egOne, baseRegistration: egOneUpgrade.registration,
            promptTemplateID: prompt)
        }
      }
    }
    // #2649: S1-mini's install path, built beside EG-1's and sharing its
    // SERVER COORDINATOR. Sharing that object is what makes one-model-at-a-time
    // true: two independently constructed coordinators would each own a process,
    // and 3.4 GB resident is the regression that would follow.
    //
    // Everything else is separate on purpose — its own manifest, its own install
    // directory, its own delivery flag, its own persisted keys. A shared value
    // there would let one model's state describe the other's.
    //
    // No upgrade coordinator: that machinery exists to retire the one shipped
    // EG-1 monolith, and S1-mini has no predecessor to retire.
    let s1Manifest = try? EGOneManifest.loadBundled(resourceName: "s1-manifest")
    // #3105: hoisted, because S1-mini's word check pins this registration's
    // admitted base exactly as EG-1's pins `egOneUpgrade.registration`.
    let s1BaseRegistration = (try? DeliveryManifest.loadBundled(resource: "s1-delivery-manifest"))
      .map { s1DeliveryManifest in
        DeliveryRegistration(
          manifest: s1DeliveryManifest,
          installDirectory: egOneAppSupport.appendingPathComponent(
            "EnviousWispr/Models/s1-mini", isDirectory: true),
          metadataDirectory: egOneAppSupport.appendingPathComponent(
            "EnviousWispr/ModelDelivery", isDirectory: true))
      }
    let s1Adapter = s1BaseRegistration.map {
      EGOneDeliveryAdapter(
        controller: modelDelivery.controller, registration: $0,
        version: s1Manifest?.resolvedDisplayVersion)
    }
    // #3105: S1-mini's word check (D5): the Debug door first, as EG-1, then the
    // delivered adapter pinned to the admitted S1-mini base.
    let s1LearnedWordAdapterProvider: @MainActor () async -> URL? = {
      if let debugS1LearnedWordAdapter { return debugS1LearnedWordAdapter.url }
      guard let base = s1BaseRegistration, let promptTemplateID = s1Manifest?.promptTemplateID
      else { return nil }
      return await modelDelivery.admittedCompatibleCheckerURL(
        engine: .s1Mini, baseRegistration: base, promptTemplateID: promptTemplateID)
    }
    let s1MiniRuntime = EGOneRuntime(
      manifest: s1Manifest, serverBinaryURL: egOneServerBinaryURL, delivery: s1Adapter,
      coordinator: egOneRuntime.serverCoordinator, provider: .s1Mini,
      learnedWordAdapterProvider: s1LearnedWordAdapterProvider)
    egOneRuntime.removeLearnedWordAdapter = { await modelDelivery.removeCheckerAdapter(.egOne) }
    s1MiniRuntime.removeLearnedWordAdapter = { await modelDelivery.removeCheckerAdapter(.s1Mini) }
    s1MiniRuntime.isActiveProvider = { [weak settings] in settings?.llmProvider == .s1Mini }
    // #2649 (cloud review): the second engine reports through the same bridge,
    // keyed by engine. Found on the "composition-root wiring" axis the class
    // sweep did not cover: every `egOneRuntime.<property> =` needs its twin.
    s1MiniRuntime.onEvent = EGOneTelemetryBridge.handler(engine: .s1Mini)
    let localPolishRuntimes = LocalPolishRuntimeSet(
      egOne: egOneRuntime, s1Mini: s1MiniRuntime)

    // Exactly one path sweeps orphans — a detached sweep alongside a spawn
    // would race it and kill the fresh server (Codex r10 P1).
    // #2649: whichever local engine is selected starts; the other only sweeps.
    // Starting both would put two models in the coordinator's start path at
    // launch, and the second would evict the first the user actually chose.
    switch settings.llmProvider {
    case .egOne:
      egOneRuntime.startIfActiveProvider()
      s1MiniRuntime.sweepStaleServersAtLaunch()
    case .s1Mini:
      s1MiniRuntime.startIfActiveProvider()
      egOneRuntime.sweepStaleServersAtLaunch()
    // No bundled server is the active provider, so neither starts and BOTH
    // sweep. #2651: the `default:` this replaces swept EG-1 only, so an S1-mini
    // server left running from a previous launch survived every subsequent
    // launch under a cloud provider, Ollama, Apple Intelligence or Off. Nothing
    // spawns on this arm, so the race the comment above guards against cannot
    // occur here.
    case .openAI, .gemini, .claude, .ollama, .appleIntelligence, .none:
      egOneRuntime.sweepStaleServersAtLaunch()
      s1MiniRuntime.sweepStaleServersAtLaunch()
    }

    // PR-5 Rung 5 (#827): the VAD signal source is App-owned and shared
    // between both kernel drivers. `audioCapture.onVADAutoStop` is bound
    // exactly once here; the factory's `assembleDriver` no longer binds
    // (Codex r2 new defect 1). Without this, the second driver's
    // construction would silently overwrite the first driver's VAD callback.
    let vadSource = KernelDictationDriverFactory.makeSharedVADSignalSource(
      audioCapture: audioCapture)

    // PR-4b.4 of #827: Parakeet recordings flow through the kernel via the
    // driver constructed by `KernelDictationDriverFactory`. The factory
    // builds the kernel + Parakeet engine adapter + lifecycle telemetry sink
    // + heart-path telemetry observer internally and wires kernel-state
    // observation post-construction (PR-4b.2).
    let makeRecoverySpoolStore = EscapeRecoveryWiring.makeSpoolStore
    // #3106 PR B: the late clipboard notice. Created BEFORE either driver, because both report into
    // it from their first dictation; connected to the overlay once `OverlayDirector` exists below.
    let retainedPasteNotice = RetainedPasteNotice()
    let kernelDriver = KernelDictationDriverFactory.makeForParakeet(
      inputs: KernelDictationDriverFactory.ParakeetInputs(
        audioCapture: audioCapture,
        asrManager: asrManager,
        parakeetUpgrade: parakeetUpgrade,
        vadSignalSource: vadSource,
        transcriptStore: transcriptStore,
        keychainManager: keychainManager,
        captureTelemetry: captureTelemetry,
        pasteCompletionRegistry: pasteCompletionRegistry,
        engineMutationScope: engineMutationScope,
        outputClassifierHolder: outputClassifierHolder,
        dictationAudioArchiveOptInProvider: { settings.isDictationAudioArchiveEnabled },
        microphonePermissionIsDenied: { permissions.microphonePermissionIsDenied },
        egOneRuntime: egOneRuntime,
        s1MiniRuntime: s1MiniRuntime,
        batchDecodeFaultController: batchDecodeFaultController,
        escapeRecovery: EscapeRecoveryWiring.wire(transcriptCoordinator),
        transcriptionCheckpoint: transcriptionCheckpoint,
        onTakeAccepted: { [retainedPasteNotice] takeID in
          retainedPasteNotice.takeAccepted(takeID)
        },
        onRetained: { [retainedPasteNotice] takeID, changeCount, reportShown in
          retainedPasteNotice.retained(
            takeID: takeID, changeCount: changeCount, reportShown: reportShown)
        },
        // #4052: the adapter's wedge recovery leaves a model EnviousMeet is decoding on alone.
        isSharedEngineHeldByOtherWorkload: { [engineLease] in
          engineLease.currentHolder == .meeting
        }
      ))

    // W6: language-flip telemetry wired via a closure so `EnviousWisprASR`
    // stays vendor-contained. The detector fires this from an actor; hop to
    // MainActor to call the @MainActor-isolated `TelemetryService`.
    let languageDetector = LanguageDetector(
      onLanguageFlip: { @Sendable event in
        Task { @MainActor in
          TelemetryService.shared.trackLanguageFlip(
            fromLang: event.fromLang,
            toLang: event.toLang,
            confidenceBoth: event.confidenceBoth
          )
        }
      }
    )

    // PR-5 Rung 5 (#827): Whisper recordings now flow through a second
    // `KernelDictationDriver` built by the factory's Whisper branch. The
    // App still builds one driver per backend; PR-6 (#827) introduced the
    // `KernelAdapterFactory` construction owner that the driver factory calls
    // into, not a single-dispatch-surface consolidation (still two drivers).
    // LID-to-polish wiring is
    // owned by `KernelFinalizationWiring.processText` via the
    // `ASREngineLanguageIdentifying` cast on the adapter; the launch warm-up
    // is owned by the shared `ensureEngineWarm(reason: .launch)` (#879).
    // #1386 PR-2: the multilingual engine's delivery wiring (owned folder,
    // migration, one gated backend, setup surface). Detail lives in
    // `WhisperDeliveryWiring`; the root just names it.
    // #1707 Phase 2: `whisper`/`whisperBackend` are constructed earlier
    // (hoisted above the Parakeet driver, see the #1707 comment near
    // `modelDelivery`) — only `whisperMigration` is extracted here, from that
    // SAME already-constructed `whisper` value.
    let whisperMigration = whisper.migration

    let whisperKernelDriver = KernelDictationDriverFactory.makeForWhisper(
      inputs: KernelDictationDriverFactory.WhisperInputs(
        audioCapture: audioCapture,
        whisperBackend: whisperBackend,
        languageDetector: languageDetector,
        vadSignalSource: vadSource,
        transcriptStore: transcriptStore,
        keychainManager: keychainManager,
        captureTelemetry: captureTelemetry,
        pasteCompletionRegistry: pasteCompletionRegistry,
        engineMutationScope: engineMutationScope,
        vendorDecodeOccupancy: asrManager.vendorDecodeOccupancy,
        whisperModelIdentity: modelDelivery.whisperRegistration?.manifest.identity
          .asrModelIdentity,
        outputClassifierHolder: outputClassifierHolder,
        dictationAudioArchiveOptInProvider: { settings.isDictationAudioArchiveEnabled },
        microphonePermissionIsDenied: { permissions.microphonePermissionIsDenied },
        egOneRuntime: egOneRuntime,
        s1MiniRuntime: s1MiniRuntime,
        batchDecodeFaultController: batchDecodeFaultController,
        escapeRecovery: EscapeRecoveryWiring.wire(transcriptCoordinator),
        transcriptionCheckpoint: transcriptionCheckpoint,
        onTakeAccepted: { [retainedPasteNotice] takeID in
          retainedPasteNotice.takeAccepted(takeID)
        },
        onRetained: { [retainedPasteNotice] takeID, changeCount, reportShown in
          retainedPasteNotice.retained(
            takeID: takeID, changeCount: changeCount, reportShown: reportShown)
        }
      ))

    // Phase F (#501) — `SetupCoordinator` needs `asrManager` + the Whisper
    // preload closure. `[weak whisperKernelDriver]` so it does not retain it.
    // The Whisper launch warm-up routes through the shared
    // `ensureEngineWarm(reason: .launch)` (gated by `SetupCoordinator` on
    // `setupState == .ready`, so it only fires for a downloaded model — never
    // an unprompted download for a non-opted-in user).
    let setup = SetupCoordinator(
      asrManager: asrManager,
      whisperSetup: whisper.setupService,
      // Fired from runDidFinishLaunching once the app is on screen. #3735: the
      // Whisper migration no longer reads `~/Documents` (the reason this was
      // deferred: a Files-and-Folders prompt before the app has drawn); it stays
      // deferred so its deletions and any download start after launch work, never
      // inside construction.
      runDocumentsMigration: { [weak whisperMigration] in
        await whisperMigration?.runLaunch()
      },
      preloadAction: { [weak whisperKernelDriver] in
        await whisperKernelDriver?.ensureEngineWarm(reason: .launch)
        #if DEBUG
          // Re-check the SELECTED and ACTIVE backend, not just this driver's
          // own readiness (#2377, C1 repair). A backend switch mid-await can
          // leave this driver `.ready` while it is no longer the one a press
          // would actually route to — emitting on its readiness alone would
          // tell the harness the wrong engine warmed, recreating the exact
          // ColdPressGuard (#879) false alarm this marker exists to avoid.
          if settings.selectedBackend == .whisper,
            asrManager.activeBackendType == .whisper,
            whisperKernelDriver?.engineReadiness == .ready
          {
            OverlayFirstRenderMarkers.emitEngineReadyOnce()
          }
        #endif
      }
    )

    // PR10 of #763 — shared `HotkeyService`. One owner so the single instance
    // threads into `HotkeyController`, `PipelineSettingsSync`,
    // `DictationLifecycleCoordinator`, and `AppDelegate` termination.
    // #1175: the live telemetry sink is constructor-injected so it is in place
    // before `start()` runs any registration (heart-path + bootstrap ordering).
    // #2455 C1/C2: the SERVICE is still constructed here, at exactly this
    // position, so construction ORDER is unchanged. What the caller supplies is
    // the desktop-effect adapter it will use — the only part that touches the OS.
    // #1175: the live telemetry sink is constructor-injected so it is in place
    // before `start()` runs any registration (heart path + bootstrap ordering).
    let hotkeyService = HotkeyService(effects: makeHotkeyEffects(), telemetry: .live)

    // 2c: the Remove drain's engine-unload seam — assignable only now that the
    // driver (and its adapter) exist; the wiring that built the coordinator ran
    // before them. L1: the drain awaits this BEFORE the delivery deletion.
    whisper.removal.unloadForRemoval = { [weak whisperKernelDriver] in
      await whisperKernelDriver?.unloadEngine()
    }
    // ONE lookup, three readers: the polish-runtime eviction rule below, the
    // import page's privacy line, and the configuration an import freezes at
    // Start. Two of those are promises to the user about where their words went,
    // so they must not be able to disagree with the third.
    let ollamaRemoteness = PipelineSettingsSync.liveOllamaRemotenessLookup(setup.ollamaSetup)
    // #3105: one eligibility owner, one engine table. Each engine brings its
    // admitted base, the prompt its adapter was trained with and its runtime.
    let checkerEligibility = LearnedWordCheckerEligibility(
      delivery: modelDelivery,
      engines: [
        .egOne: .init(
          base: egOneUpgrade?.registration, promptTemplateID: egOneManifest?.promptTemplateID,
          runtime: egOneRuntime, debugThreshold: debugLearnedWordAdapter?.threshold),
        .s1Mini: .init(
          base: s1BaseRegistration, promptTemplateID: s1Manifest?.promptTemplateID,
          runtime: s1MiniRuntime, debugThreshold: debugS1LearnedWordAdapter?.threshold),
      ],
      debugScriptedChecker: debugScriptedChecker)
    egOneRuntime.onEvent = { event in
      EGOneTelemetryBridge.handler(engine: .egOne)(event)
      Task { @MainActor in checkerEligibility.statusDidChange() }
    }
    s1MiniRuntime.onEvent = { event in
      EGOneTelemetryBridge.handler(engine: .s1Mini)(event)
      Task { @MainActor in checkerEligibility.statusDidChange() }
    }
    // Founder 2026-09-26 (#3105): every INSTALLED engine gets its word check,
    // selected or not. Two triggers per engine: launch (EG-1's runs after its
    // upgrade pass above; S1-mini has none, so here) and the base's own
    // admission, which is what a first-time download of either engine reaches.
    // Selection and import activation never fetch.
    Task { await checkerEligibility.requestAdapterDownload(for: .s1Mini) }
    let runtimes: [LearnedWordCheckerEngine: EGOneRuntime] = [
      .egOne: egOneRuntime, .s1Mini: s1MiniRuntime,
    ]
    for engine in LearnedWordCheckerEngine.allCases {
      guard let checkerIdentity = modelDelivery.checkerRegistrations[engine]?.manifest.identity,
        let runtime = runtimes[engine]
      else { continue }
      let baseIdentity: ModelIdentity? =
        switch engine {
        case .egOne: egOneUpgrade?.registration.manifest.identity
        case .s1Mini: s1BaseRegistration?.manifest.identity
        }
      // Act on admission EDGES only. A runtime refresh can re-adopt the base,
      // which republishes `.admitted`; acting on every event would request the
      // checker again and refresh the runtime again (confirming review of #3227).
      let edges = AdmissionEdges()
      Task {
        await modelDelivery.controller.addStateObserver { identity, state in
          let admitted: Bool
          if case .admitted = state { admitted = true } else { admitted = false }
          if identity == baseIdentity {
            guard edges.changed(identity, admitted: admitted), admitted else { return }
            Task { @MainActor in await checkerEligibility.requestAdapterDownload(for: engine) }
            return
          }
          guard identity == checkerIdentity else { return }
          let admissionChanged = edges.changed(identity, admitted: admitted)
          Task { @MainActor in
            // The Dictionary row follows every step of the download; the
            // server restarts only when admission itself turns on or off.
            checkerEligibility.statusDidChange()
            if admissionChanged { runtime.adapterAvailabilityDidChange() }
          }
        }
      }
    }
    let settingsSync = PipelineSettingsSync(
      kernelDriver: kernelDriver,
      whisperKernelDriver: whisperKernelDriver,
      audioCapture: audioCapture,
      asrManager: asrManager,
      hotkeyService: hotkeyService,
      egOneRuntime: egOneRuntime,
      s1MiniRuntime: s1MiniRuntime,
      checkerSelectionProvider: { [checkerEligibility] provider, language in
        await checkerEligibility.selection(provider: provider, language: language)
      },
      ollamaRemotenessLookup: ollamaRemoteness,
      importPinnedLocalProvider: { fileImportCoordinatorForGates?.pinnedLocalPolishProvider },
      importPinnedOllamaModel: { fileImportCoordinatorForGates?.pinnedOllamaModel },
      outputClassifierHolder: outputClassifierHolder,
      loadOutputClassifier: { [outputClassifierHolder] in
        WisprBootstrapper.prewarmOutputClassifier(holder: outputClassifierHolder)
      },
      // #3853: the same held-engine-plus-frozen-provider read the word check uses (#3289).
      importPinnedPolishProvider: {
        guard fileImportCoordinatorForGates?.isEngineHeld == true else { return nil }
        return fileImportRunnerForGates?.frozenLLMProvider
      }
    )
    settingsSync.applyInitialSettings(settings)
    // #3242: the word check for polish engines without their own. Held by the eligibility
    // owner (its only reader); driven by the Dictionary switch and both engine choices.
    let wordCheck = WordCheckRuntime(
      delivery: modelDelivery,
      isDictionaryEnabled: { [weak settings] in settings?.wordCorrectionEnabled ?? false },
      someEngineLacksOwnChecker: { [weak settings] in
        guard let settings else { return false }
        return LearnedWordCheckerEngine(provider: settings.llmProvider) == nil
          || LearnedWordCheckerEngine(provider: settings.effectiveFileImportLLMProvider) == nil
      },
      isOnboardingComplete: { [weak settings] in settings?.onboardingState == .completed })
    wordCheck.onStatusChange = { [checkerEligibility] in checkerEligibility.statusDidChange() }
    checkerEligibility.wordCheck = wordCheck
    settingsSync.onWordCheckInputsChanged = { [weak wordCheck] in
      wordCheck?.refresh(trigger: .settingsChanged)
    }

    // #1988: the live-preview limb, wired ONLY to the overlay. See the installer.
    //
    // **This runs BEFORE the director now** (#2292 C2) and hands back a bridge
    // rather than pushing providers into an overlay that had to already exist.
    let livePreviewInstallation = LivePreviewInstaller.install(
      capture: audioCapture, settings: settings,
      settingsSync: settingsSync, modelDelivery: modelDelivery)
    let livePreview = livePreviewInstallation.coordinator

    // **The director is constructed HERE, roughly 360 lines below where it used
    // to be, and this is the whole point of C2.** Its Live Preview seams are now
    // required at construction, and they cannot exist any earlier: the installer
    // needs `audioCapture` and `settingsSync`, and `PipelineSettingsSync` is
    // downstream of both ASR pipelines. So the director moved to its
    // dependencies rather than its dependencies moving to it.
    //
    // Nothing outside this function can observe the move: `EnviousWisprApp`
    // completes `WisprBootstrapper()` before `appDelegate.attach(bootstrapper:)`,
    // so the director exists before any lifecycle callback, any scene, or any
    // recording. Its own `init` creates no panel, hosting view, status item or
    // task.
    let recordingOverlay = OverlayDirector(
      host: overlayHost,
      position: { settings.overlayPillPosition },
      accessibilityEligibility: OverlayAccessibilityEligibility(
        warningDismissed: { [weak permissions] in
          permissions?.accessibilityWarningDismissed ?? false
        }),
      livePreview: livePreviewInstallation.bridge,
      // Grant leaves the router in C2, captured STRONGLY on purpose. The
      // router's targets were weak because they were settable and their feature
      // owners anchored them; a REQUIRED construction argument has the opposite
      // obligation — a weak capture reintroduces the silent failure this
      // parameter exists to make unspellable, where the button renders and
      // reaches nobody.
      //
      // No cycle: `PermissionsService` lives in `EnviousWisprServices`, which is
      // downstream of this module and cannot name `OverlayDirector` — zero hits.
      // Its one callback has a single assignment (`MenuBarController.swift:76`)
      // and that captures weakly. `WisprBootstrapper` owns the service for the
      // app's lifetime regardless.
      grantAccessibility: { _ = permissions.requestAccessibilityAccess() },
      // #2549: the notice pill's "Open Settings" button, on the SAME shared
      // owner Part 2 of #2549 already gave the Settings page and onboarding.
      openMicrophoneSettings: {
        Task { await permissions.requestMicrophoneAccessOrOpenSettings() }
      },
      // #2664: the silent-take advisory names the multi-input device the user
      // would find selected in Settings right now. Same device rule as the
      // settings row (`InputSocket.socketDevice`), same strong captures as the
      // closures beside it — the bootstrapper owns both for the app's lifetime.
      advisoryHint: { reason in
        MultiInputAdvisoryHint.make(
          reason: reason,
          socketDevice: InputSocket.socketDevice(
            preferredInputDeviceIDOverride: settings.preferredInputDeviceIDOverride,
            devices: audioDeviceList.availableInputDevices,
            resolvedAutoInputDeviceID: AudioDeviceEnumerator.resolvedAutoInputDeviceID))
      },
      // **THE SEAM PHASE 3 LEFT, NOW SPENT** (#2376 Phase 4, C6). It is a closure
      // so that it can be: the director lives for the app's lifetime, so a stored
      // pair would freeze the user's choice at launch — a picker would appear to
      // work, change nothing, and only take effect after a relaunch.
      //
      // Phase 3 returned a constant and predicted that Phase 4 would replace this
      // closure's BODY and nothing else: not `PillCatalog.entry`, not
      // `DesignResolution`, not the call site, not where the director resolves
      // capability. That held — this is the only line of composition that moved.
      //
      // `settings` is captured strongly, exactly as `position:` above captures it,
      // and the bootstrapper owns both for the app's lifetime so there is no
      // cycle. Every party is already `@MainActor`, so there is no hop and nothing
      // to make `Sendable`.
      selections: {
        PillDesignSelections(
          withoutWords: settings.recordingPillDesignWithoutWords,
          withWords: settings.recordingPillDesignWithWords)
      })
    // #2377 Phase 6 C4: stored immediately so `applicationDidFinishLaunching()`
    // can reach it later. Every use below this line keeps reading the bare
    // `recordingOverlay` identifier, which still resolves to this same local —
    // Swift resolves an unqualified name to the innermost declaration in
    // scope, and the local shadows the property for the rest of `init`.
    self.recordingOverlay = recordingOverlay
    // #3106 PR B: the late clipboard notice can present from here on. Held strongly by both
    // drivers' callbacks; the director is held weakly by the notice.
    retainedPasteNotice.connect(recordingOverlay)
    // #3546 A3: the Parakeet Ultra upgrade's downloading and ready pills. Only with the Ultra
    // target is there an upgrade to show. Chained after the telemetry observer the delivery
    // home installed, which keeps receiving every outcome first.
    if let ultraCacheKey = parakeetUpgrade.upgradeTargetCacheKey {
      let upgradePills = ParakeetUpgradePillPresenter(
        overlay: recordingOverlay, targetCacheKey: ultraCacheKey,
        isUltraReady: { [settings, asrManager, parakeetUpgrade] in
          settings.selectedBackend == .parakeet && asrManager.activeBackendType == .parakeet
            && asrManager.isModelLoaded && parakeetUpgrade.presentedModel == .ultra
        })
      let upstreamOutcome = parakeetUpgrade.onOutcome
      parakeetUpgrade.onOutcome = { outcome in
        upstreamOutcome?(outcome)
        upgradePills.observe(outcome)
      }
      let upstreamBackground = parakeetUpgrade.onBackgroundUpgradeChanged
      parakeetUpgrade.onBackgroundUpgradeChanged = { state in
        upstreamBackground?(state)
        upgradePills.backgroundUpgradeChanged(state)
      }
    }

    // #996 chunk 5h: composed here because every collaborator it needs already
    // exists (settings, the word list, the packs, the overlay director, the
    // paste registry, the delivery home) and `settings.onChange` below needs
    // it. Phase D: the delivered judge's fetch, load and selection live inside.
    let learnFromEdits = LearnFromEditsWiring(
      settings: settings,
      customWords: customWordsCoordinator,
      packs: vocabularyPackManager,
      overlay: recordingOverlay,
      pasteCompletionRegistry: pasteCompletionRegistry,
      telemetry: WisprBootstrapper.learnFromEditsTelemetrySink(),
      deliveryHome: modelDelivery,
      isOnboardingComplete: { [weak settings] in settings?.onboardingState == .completed })
    self.learnFromEdits = learnFromEdits

    // #2376 C7: the Appearance page's window onto the pill. Built HERE because
    // this is where the live-preview bridge already is, so the picker reads the
    // same capability the director does rather than re-deriving one.
    let pillAppearance = PillAppearanceModel(
      settings: settings, capability: livePreviewInstallation.bridge.wordsCapability)
    // Removal suppression is the one capability input no settings key records, so
    // it has to be pushed. Weak, for the reason every other hook into this limb is
    // weak: a settings page must never be what keeps it alive.
    livePreview.onWordsCapabilityMayHaveChanged = { [weak pillAppearance] in
      pillAppearance?.capabilityDidChange()
    }

    // #1701 Chunk 2: bulk-import-enrichment producer, a sibling of
    // `contactsImportCoordinator` on the same alias-suggester permit lane.
    // Moved down with the director (#2292 C2). Construction and scanning are both
    // unconditional: without this wiring `onImportCommitted` stays nil and a
    // committed import never enriches.
    //
    // The WHOLE block moves because `presentStatus` closes over
    // `recordingOverlay`; leaving it above the director would need the mutable
    // forward-reference shape this chunk removes. `requestDrain()` stays after
    // both callbacks and before `wireCustomWords`, unchanged from before the
    // move — its MainActor task cannot run until this synchronous initializer
    // yields, which it does not do before returning.
    let bulkImportEnrichmentCoordinator = BulkImportEnrichmentCoordinator(
      customWords: customWordsCoordinator,
      aliasSuggester: customWordsCoordinator.aliasSuggester,
      presentStatus: { [weak recordingOverlay] message in
        recordingOverlay?.present(.importStatus(message: message))
      })
    customWordsCoordinator.onImportCommitted = { [weak bulkImportEnrichmentCoordinator] in
      bulkImportEnrichmentCoordinator?.requestDrain()
    }
    customWordsCoordinator.cancelBulkImportEnrichment = {
      [weak bulkImportEnrichmentCoordinator] in
      bulkImportEnrichmentCoordinator?.cancel()
    }
    bulkImportEnrichmentCoordinator.requestDrain()

    // #1224 (#1543): the VAD source reports a typed readiness FACT when the
    // bundled model can't load. The App shell emits a typed in-panel notice and
    // `DictationNarrator` owns the user-facing sentence (#1567). The notice
    // no-ops when no recording panel is showing.
    //
    // `vadSource` itself stays where it is built, above; only this BINDING moved
    // down with the director. The notice can only fire during a recording, which
    // cannot start until bootstrap returns, so no reachable interval exists where
    // it is unbound.
    // Share one closure between VAD production and DEBUG staging so both exercise
    // the same notice and expiry path.
    let presentAutoStopUnavailableNotice: @MainActor () -> Void = { [weak recordingOverlay] in
      recordingOverlay?.update(.inPanelNotice(.autoStopUnavailable, dismissAfter: 4.0))
    }
    vadSource.onAutoStopUnavailableNotice = presentAutoStopUnavailableNotice
    #if DEBUG
      DebugOverlayStaging.presentAutoStopUnavailableNotice = presentAutoStopUnavailableNotice
    #endif

    // Custom-words propagator wiring (seed → register consumers → install
    // `onWordsChanged`). Phase D (#496). `wireCustomWords` strong-captures the
    // propagator so its lifetime is anchored to `customWordsCoordinator`.
    wireCustomWords(
      propagator: customWordsPropagator,
      initialWords: customWordsCoordinator.customWords,
      correctorConsumers: [
        kernelDriver.wordCorrection,
        kernelDriver.learnedWordCheck,
        whisperKernelDriver.wordCorrection,
        whisperKernelDriver.learnedWordCheck,
        // #1988: the preview corrects displayed text with the SAME lane, so a
        // user's own names do not visibly mangle while the pasted text is fixed.
        livePreview,
      ],
      polishConsumers: [
        kernelDriver.llmPolish,
        whisperKernelDriver.llmPolish,
      ],
      coordinator: customWordsCoordinator,
      packManager: vocabularyPackManager
    )

    // #628 snippet wiring. TWO drivers, and seeding one is half the job — the same shape the
    // custom-words wiring above has to satisfy. Seed both now, then republish on every change
    // so a snippet saved mid-session is live on the next dictation without a relaunch.
    //
    // KNOWN LIMIT, stated rather than claimed away: this replaces the vocabulary on the live
    // step, so a snippet edited WHILE a dictation is in flight applies to that take. The step's
    // own header used to call this a per-take freeze, and that was an overclaim — corrected
    // there. It matches how custom words already behave (`CustomWordsPropagator` can replace
    // `correctorVocabulary` mid-session, which `KernelFinalizationWiring` says out loud), and
    // the outcome is that the user's NEWEST snippet wins rather than any data being wrong.
    // A real record-start freeze is a separate change with a hook recording does not have yet.
    //
    // Recovery is wired separately, at `RecoverySpoolReplayer`'s `currentSnippets` provider,
    // because that processor is built per replay.
    let seedSnippets: @MainActor (SnippetVocabulary) -> Void = {
      [kernelDriver, whisperKernelDriver] vocabulary in
      kernelDriver.snippetExpansion.snippetVocabulary = vocabulary
      whisperKernelDriver.snippetExpansion.snippetVocabulary = vocabulary
    }
    seedSnippets(snippetsCoordinator.vocabulary)
    snippetsCoordinator.onVocabularyChanged = seedSnippets

    // Restore persisted backend selection synchronously (no race with first record).
    asrManager.setInitialBackendType(settings.selectedBackend)
    SentryBreadcrumb.updateASRBackend(settings.selectedBackend.rawValue)
    ASRModelScopeOwner.shared.activate(settings.selectedBackend)

    // #1173: settings-change telemetry observer. `emitBaseline` re-emits the
    // comprehensive `settings.snapshot` at onboarding-completion (fixes the
    // first-run gap for a long-running app). Built before the funnel is wired.
    // #2997: one builder for both emission points (launch, via the lifecycle coordinator,
    // and onboarding completion, via the settings funnel). The snippet state rides as two
    // closures so the builder depends on one coordinator type.
    let standingSnapshotBuilder = StandingSnapshotBuilder(
      settings: settings, keychainManager: keychainManager,
      customWordsCoordinator: customWordsCoordinator, permissions: permissions,
      snippetsCount: { [snippetsCoordinator] in snippetsCoordinator.snippets.count },
      snippetsKeywordIsDefault: { [snippetsCoordinator] in
        snippetsCoordinator.keyword == SnippetVocabulary.defaultKeyword
      })
    let settingsChangeTelemetry = SettingsChangeTelemetry(
      settings: settings,
      emitBaseline: { standingSnapshotBuilder.emit() })
    // #1173: drain a pending settings delta before any telemetry flush (quit /
    // update-relaunch) so a change made inside the debounce window isn't lost.
    TelemetryService.shared.onBeforeFlush = { [weak settingsChangeTelemetry] in
      settingsChangeTelemetry?.flush()
    }

    // PR-B.2 of #763: window-lifecycle home, and since #2480 the sole owner of the
    // Dock policy. **Built HERE, before `settings.onChange` and Sparkle, because both
    // report to it** (the "Show app in Dock" switch, the update dialog). Its inputs,
    // `presentationEffects` and `settings`, already exist, so this is a reorder, not
    // a late-bound seam: same reasoning as `MenuBarController` below.
    let appWindowCoordinator = AppWindowCoordinator(
      application: presentationEffects.application,
      // Strong: `settings` holds no reference back to the coordinator, and a nil fallback
      // would be a second copy of the default, which lives only in `SettingsDefaultValues`.
      showInDock: { [settings] in settings.showInDock },
      canOpenOnboarding: { [weak settings] in
        guard let settings else { return false }
        return settings.onboardingState != .completed
      },
      isOnboardingComplete: { [weak settings] in
        settings?.onboardingState == .completed
      }
    )

    // #1480: late-binding bridge so this early-assigned onChange closure can
    // forward setting-change facts to the (later-constructed) presenter.
    let bluetoothAwarenessPresenterHolder = BluetoothAwarenessPresenterHolder()
    // #3438: the same late binding for the setup-warning monitor, built further down. Its
    // configuration and eligibility move here, synchronously, never only by later observation.
    let polishSetupMonitorHolder = PolishSetupMonitorHolder()
    let menuBarControllerHolder = MenuBarControllerHolder()
    // #3289 §8b: the same late binding for the idle-memory observer, built further down; a usage
    // metrics change restarts its idle stretch.
    weak var idleMemoryObserverForSettings: IdleMemoryObserver?

    settings.onChange = {
      [
        weak settingsSync, weak settings, weak settingsChangeTelemetry,
        bluetoothAwarenessPresenterHolder, weak egOneCoordinator = egOneUpgrade?.coordinator,
        weak learnFromEdits, weak appWindowCoordinator, polishSetupMonitorHolder,
        menuBarControllerHolder
      ] key
      in
      guard let settingsSync, let settings else { return }
      settingsSync.handleSettingChanged(key, settings: settings)
      if key == .shareUsageMetrics { idleMemoryObserverForSettings?.usageMetricsChanged() }
      switch key {
      case .llmProvider, .llmModel, .ollamaModel, .onboardingState:
        polishSetupMonitorHolder.monitor?.configurationOrEligibilityChanged()
      default: break
      }
      // #1173: emit coalesced settings.changed deltas (fire-and-forget, never
      // throws/awaits into the setter path).
      settingsChangeTelemetry?.handle(key)
      // #996: the learn-from-edits toggle reaches the watcher (cancels a live
      // watch on off; re-read at every boundary otherwise).
      learnFromEdits?.settingChanged(key, settings: settings)
      // #2480: the Dock switch takes effect now, not at the next window close.
      if key == .showInDock {
        appWindowCoordinator?.refreshActivationPolicy(excluding: nil)
      }
      // #3441: the update-alert switch changes the menu bar icon now.
      if key == .showMenuBarUpdateAlert {
        menuBarControllerHolder.controller?.updateIcon()
      }
      // #1047: appearance is a view-shell concern (no pipeline sync) — apply it
      // to NSApp here so both the menu and the Settings picker take effect live.
      if key == .appearance {
        AppearanceController.apply(settings.appearancePreference)
      }
      // #832/#913 PR8, #3853: a polish-provider change loads or releases the output classifier
      // inside `settingsSync.handleSettingChanged` above (`reconcileOutputClassifierDemand`).
      // #2096: EG-1's automatic model upgrade stands aside while first-run setup runs, so the
      // heart's model download owns the bandwidth. `runLaunch` fires once at bootstrap, so
      // without this the deferral would mean "never until relaunch" rather than "later".
      // #3242: the word check needs first-run setup done, so every onboarding change (completion,
      // or a Diagnostics reset) re-evaluates its download and residency.
      if key == .onboardingState {
        checkerEligibility.wordCheck?.refresh(trigger: .onboardingChanged)
      }
      if key == .onboardingState, settings.onboardingState == .completed {
        Task {
          guard await egOneCoordinator?.onboardingDidComplete() == true else { return }
          egOneRuntime.activateAfterAutomaticReplacementIfNeeded()
        }
        // #996 phase D: the judge downloads after first-run setup, never during it.
        learnFromEdits?.onboardingDidComplete()
        // #3546 E22: a held background Parakeet upgrade starts now.
        parakeetUpgrade.onboardingDidComplete()
      }
      // #1480: tips on/off, input-device change, and onboarding completion each
      // re-evaluate the Bluetooth card (dismiss/suppress, route re-check, or first
      // surface after onboarding). Deferred to the next run-loop cycle because the
      // input picker writes `preferredInputDeviceIDOverride` and
      // `selectedInputDeviceUID` as a synchronous PAIR (AudioSettingsView), so a
      // reconcile on the first write would read a half-updated selection (cloud
      // review P2). Deferring coalesces the pair into one evaluation over the
      // settled state; the second fires and no-ops.
      switch key {
      case .showBluetoothTips, .preferredInputDeviceIDOverride, .selectedInputDeviceUID,
        .onboardingState:
        DispatchQueue.main.async {
          bluetoothAwarenessPresenterHolder.presenter?.reconcile(trigger: .settingChanged)
        }
      default:
        break
      }
    }

    // Pre-load the selected backend's model in the background to eliminate
    // cold-start delay. Parakeet: shared warm-up via the active driver.
    // Whisper: observation-based (waits for setupState to become .ready
    // first, then `preloadAction` → `ensureEngineWarm`).
    // #3546 row T: Settings' Try again loads right after the granted cycle,
    // through the same guarded warm-up, only while Parakeet is selected and
    // active.
    modelDelivery.warmParakeetAfterExplicitRetry = { [weak kernelDriver, asrManager] in
      guard settings.selectedBackend == .parakeet,
        asrManager.activeBackendType == .parakeet
      else { return }
      _ = await kernelDriver?.ensureEngineWarm(reason: .explicitRetry)
    }

    if settings.selectedBackend == .parakeet {
      // #3546: launch is a model-selection point.
      parakeetUpgrade.markSelectionPoint()
      Task { [weak kernelDriver] in
        // Discard the outcome so the Task's Success type stays Void
        // (`EngineWarmupOutcome` does not declare Sendable conformance).
        _ = await kernelDriver?.ensureEngineWarm(reason: .launch)
        #if DEBUG
          // Same re-check as the Whisper path, mirrored: the SELECTED and
          // ACTIVE backend, not just this driver's own readiness (#2377, C1
          // repair).
          if settings.selectedBackend == .parakeet,
            asrManager.activeBackendType == .parakeet,
            kernelDriver?.engineReadiness == .ready
          {
            OverlayFirstRenderMarkers.emitEngineReadyOnce()
          }
        #endif
      }
    }

    let navigationCoordinator = NavigationCoordinator()
    // #1386 PR-2: the one door to whichever engine is active, for the callers
    // that never used the normal dictation doors — crash recovery, Diagnostics,
    // and since #2648 file import, which needs the engine the user picked on the
    // Transcription step rather than the one the manager happens to own.
    let activeEngine = ActiveEngineOperation.live(
      asrManager: asrManager, parakeetUpgrade: parakeetUpgrade,
      whisperBackend: whisperBackend)

    // The benchmark is a FOURTH workload on the one inference slot, so it takes
    // the same claim a dictation, a replay and an import take. Built here rather
    // than inside `DiagnosticsCoordinator`, which should not know about the
    // pipeline: its job is owning the surface.
    let diagnosticsCoordinator = DiagnosticsCoordinator(
      benchmark: BenchmarkSuite(
        engineMutationScope: engineMutationScope, engineLease: engineLease,
        isEngineSwitching: { engineCoordinatorForRecoveryGate?.isSwitching ?? false }))

    // **Two arguments, and no self-reference problem to solve** (#2292 C3).
    // This used to hand over three closures, one of which resolved the chip's
    // buttons through the router BECAUSE the presenter they belonged to did not
    // exist yet. The buttons now ride on the chip's own request, which the
    // presenter builds in a method, so `self` is simply in scope.
    let languageSuggestionPresenter = LanguageSuggestionPresenter(
      overlay: recordingOverlay,
      onLanguageAccepted: OverlayChipWiring.acceptedLanguage(settings: settings)
    )
    // Wires the `LanguageDetector` actor's passive-chip callback to the
    // presenter. The presenter is captured directly (App-lifetime `@State`).
    Task {
      await languageDetector.setPassiveChipHandler {
        @Sendable (trigger: PassiveChipTrigger) in
        Task { @MainActor in
          languageSuggestionPresenter.bufferTrigger(trigger)
        }
      }
    }

    let updateCoordinatorHolder = UpdateCoordinatorHolder()
    let sparkleUpdateController = SparkleUpdateController(
      holder: updateCoordinatorHolder, updateDialogPresenter: appWindowCoordinator)

    // #1019: event-driven update-discovery triggers (wake / network). Data-free
    // — it reads `updateCoordinator` lazily (nil until `startUpdater()`), so it
    // tolerates being constructed before Sparkle boots.
    let updateTriggerCoordinator = UpdateTriggerCoordinator(
      onTrigger: { [weak sparkleUpdateController] trigger in
        sparkleUpdateController?.updateCoordinator?.checkForUpdatesProactively(trigger: trigger)
      })

    let liveRecordingState = LiveRecordingState(
      kernelDriver: kernelDriver,
      whisperKernelDriver: whisperKernelDriver,
      audioCapture: audioCapture,
      asrManager: asrManager
    )
    // #1063 PR2: crash-recovery owner. The per-orphan replayer (decrypt →
    // transcribe → polish → save) is built from existing app deps; the coordinator
    // owns the launch scan, the recording gate, dedup, and cleanup routing. The
    // key store + spool-store factory are shared so arm/recover/cleanup agree on
    // backend + paths.
    let recoveryKeyStore = RecoveryKeyStore()
    let recoverySpoolReplayer = RecoverySpoolReplayer(
      activeEngine: activeEngine,
      keyStore: recoveryKeyStore,
      makeSpoolStore: makeRecoverySpoolStore,
      transcriptStore: transcriptStore,
      transcriptCoordinator: transcriptCoordinator,
      keychainManager: keychainManager,
      outputClassifierHolder: outputClassifierHolder,
      egOneRuntime: egOneRuntime,
      s1MiniRuntime: s1MiniRuntime,
      checkerSelectionProvider: { [checkerEligibility] provider, language in
        await checkerEligibility.selection(provider: provider, language: language)
      },
      // #3289: start loading the word check behind the recovered recording's transcription when
      // its frozen polish engine uses it (the model is no longer loaded at launch).
      // #3853: and the output classifier counts the replay as a consumer, by the same provider.
      onReplayWillTranscribe: { [weak checkerEligibility, weak settingsSync, settings] provider in
        checkerEligibility?.wordCheck?.recoveryStarted(
          needsWordCheck: LearnedWordCheckerEngine(provider: provider) == nil)
        settingsSync?.outputClassifierRecoveryStarted(provider: provider, settings: settings)
      },
      onReplayFinished: { [weak checkerEligibility, weak settingsSync, settings] provider in
        checkerEligibility?.wordCheck?.recoveryFinished(
          needsWordCheck: LearnedWordCheckerEngine(provider: provider) == nil)
        settingsSync?.outputClassifierRecoveryFinished(provider: provider, settings: settings)
      },
      // Best-effort: the snapshot carries only the custom-words version, so recovery
      // applies the user's CURRENT words (pack terms omitted) — normal-quality, not
      // byte-exact. `+ 1` keeps the cache generation non-zero so terms take effect.
      currentVocabulary: { [customWordsCoordinator] in
        LanePartitioner.split(
          customWordsCoordinator.customWords,
          generation: UInt64(customWordsCoordinator.customWords.count) &+ 1)
      },
      currentSnippets: { [snippetsCoordinator] in snippetsCoordinator.vocabulary })
    // #1741 Chunk 2 — the recovery-side capability, required at construction
    // (replacing the post-init `tryBeginRecoveryClaim`/`endRecoveryClaim`
    // closure assignments this plan removes below).
    let recoveryEngineClaim = RecoveryEngineClaim.live(
      tryBegin: { [engineRecoveryGate] in engineRecoveryGate.tryBeginRecovery() },
      end: { [engineRecoveryGate] in engineRecoveryGate.endRecovery() })
    let recoveryCoordinator = RecoveryCoordinator(
      keyStore: recoveryKeyStore,
      makeSpoolStore: makeRecoverySpoolStore,
      replayer: recoverySpoolReplayer,
      // #2087: BOTH namespaces — the store owns the definition.
      existingRecoveryIDs: { [transcriptStore] in
        (try? await transcriptStore.allRecoveredSessionIDs()) ?? []
      },
      isDictationActive: { [liveRecordingState] in
        liveRecordingState.isDictationActive
          || (engineCoordinatorForRecoveryGate?.isMintingAnySession ?? false)
      },
      recoveryEngineClaim: recoveryEngineClaim,
      // #2648 — a replay runs the same polish server a dictation does, so it
      // takes the same one-workload claim for the whole item.
      engineAdmission: .live(lease: engineLease, as: .crashRecovery),
      // Discard hard-resets the ACTIVE engine (#445 service-kill) so an in-flight,
      // otherwise-uncancellable recovery load/transcribe aborts and the next
      // recording gets a clean engine. Routed through the active-engine door
      // because recovery itself runs there: resetting only the Parakeet manager
      // would leave a Whisper recovery uncancellable (Codex 2b-r2 P1).
      resetEngine: { [activeEngine] in Task { await activeEngine.hardCancel() } })
    // #1741 Chunk 3 — now that `recoveryCoordinator` exists, the shared
    // `engineMutationScope`'s wake closure (constructed before `asrManager`,
    // above) can reach it.
    recoveryCoordinatorForEngineMutationScope = recoveryCoordinator
    // #1807 (§C) — the one narrow Audio→Coordinator wire this chunk adds:
    // Audio's writer-completion ack (fired for a real writer AND for every
    // explicit no-writer case) tells the coordinator's per-session join that
    // this session's writer will never touch its spool again. Direct wiring,
    // no Pipeline involvement — matches the plan's proposed shape.
    audioCaptureManager.onRecoveryWriterQuiescent = { [weak recoveryCoordinator] sessionID in
      recoveryCoordinator?.acknowledgeWriterQuiescent(recoverySessionID: sessionID)
    }
    // #1063 PR2: the "recovering" pill's Discard action.

    // #1464: after a leftover recording lands in History, post the standalone green
    // success notice (the `.recovered` path was silent before).
    recoveryCoordinator.onRecoverySucceeded = { [weak recordingOverlay] in
      recordingOverlay?.present(.recoverySucceeded)
    }
    // #1171 — the single owner of ASR-engine selection, status, and switching.
    // Reads the user's choice + active engine + readiness LIVE (no stored "want"
    // copies); serializes switches through one mailbox; defers while a pipeline is
    // active, recovery is replaying, or the active engine is mid-load; publishes
    // one `EngineStatus`. Built here (after recoveryCoordinator, so it can read
    // `isRecovering`; before BackendMetadata + DictationRuntime, which consume it).
    let engineCoordinator = EngineCoordinator(
      dependencies: EngineCoordinator.Dependencies(
        selectedBackend: { settings.selectedBackend },
        activeBackend: { [asrManager] in asrManager.activeBackendType },
        readiness: { [kernelDriver, whisperKernelDriver] backend in
          (backend == .whisper ? whisperKernelDriver : kernelDriver).engineReadiness
        },
        // #2787: an engine whose abandoned decode is still running is ACTIVE
        // for switching purposes, whatever the pipeline state says.
        isEngineActive: { [kernelDriver, whisperKernelDriver, engineLease] backend in
          engineLease.currentHolder == .abandonedDecode
            || (backend == .whisper ? whisperKernelDriver : kernelDriver).state.isActive
        },
        isRecovering: { [weak recoveryCoordinator] in recoveryCoordinator?.isRecovering ?? false },
        // `isEngineHeld`, not `isRunning`: Stop flips the visible state at the
        // press while the cancelled work is still inside the engine, and a
        // switch admitted in that window unloads the backend underneath it.
        isFileImportRunning: { fileImportCoordinatorForGates?.isEngineHeld ?? false },
        isEngineHeld: { [engineLease] in engineLease.isBusy },
        isMeetingEngineResident: { [meetingBox] in
          meetingBox.coordinator?.isMeetingModelWorkActive ?? false
        },
        isMeetingOwnParakeetResident: { [meetingBox] in
          meetingBox.coordinator?.isFinalPassOwnParakeetResident ?? false
        },
        isInstalled: { [setup] backend in
          backend == .parakeet ? true : setup.whisperSetup.setupState == .ready
        },
        stateLabel: { [kernelDriver, whisperKernelDriver] backend in
          (backend == .whisper ? whisperKernelDriver : kernelDriver).state.telemetryLabel
        },
        performSwitch: { [asrManager, parakeetUpgrade, whisperKernelDriver, meetingWakes] backend in
          // #3546 E21: an actual transition INTO Parakeet is a selection point;
          // re-selecting the already-active Parakeet is not.
          if backend == .parakeet, asrManager.activeBackendType != .parakeet {
            parakeetUpgrade.markSelectionPoint()
          }
          await Self.switchEngine(
            to: backend, activeBackend: { asrManager.activeBackendType },
            parkWhisper: { await whisperKernelDriver.parkEngine() },
            switchManager: { backend in
              await asrManager.switchBackend(to: backend)
            },
            unparkWhisper: { await whisperKernelDriver.unparkEngine() },
            log: { line in
              await AppLogger.shared.log(line, level: .info, category: "ASR")
            })
          SentryBreadcrumb.updateASRBackend(backend.rawValue)
          // #3546 §3.7 T3: the model tags follow the engine now active.
          ASRModelScopeOwner.shared.activate(backend)
          // #4052: a meeting pass waiting for the switch to settle chooses its route now.
          meetingWakes.poke()
        },
        warm: { [kernelDriver, whisperKernelDriver] backend in
          await (backend == .whisper ? whisperKernelDriver : kernelDriver)
            .ensureEngineWarm(reason: .engineSwap)
        },
        // #1707 Phase 3 (§3.2, row 4) / #1741 Chunk 7: `startWarm()`'s
        // background convenience warm must never race recovery on the shared
        // engine — guarded by the one shared `engineMutationScope`.
        engineMutationScope: engineMutationScope,
        // #3546 A3: the in-session Ultra activation at the first quiet moment. Marks the
        // selection point the next Parakeet load consumes, releases v3 through the same
        // unload the idle timer uses, then warms; the load's own plan (row A, A-fail, E19)
        // decides whether Ultra or v3 serves.
        isParakeetActivationOwed: { [parakeetUpgrade] in parakeetUpgrade.isActivationOwed },
        activateParakeetUpgrade: { [parakeetUpgrade, asrManager, kernelDriver] in
          guard parakeetUpgrade.beginOwedActivation() else { return }
          // An idle-unload timer firing mid-load would cancel the Ultra load it lands on.
          kernelDriver.cancelPendingEngineUnload()
          await asrManager.unloadModel()
          // The quiet gates exclude a live stream and recovery, the unload's only two
          // refusals. If v3 is somehow still resident, load nothing now: the marked
          // selection point waits for the next real load, so two models never load.
          guard !asrManager.isModelLoaded else {
            await AppLogger.shared.log(
              "Parakeet upgrade activation: v3 unload refused; Ultra waits for the next load",
              level: .info, category: "Upgrade")
            return
          }
          _ = await kernelDriver.ensureEngineWarm(reason: .engineSwap)
        }))
    parakeetUpgrade.onActivationOwed = { [weak engineCoordinator] in
      engineCoordinator?.poke(.parakeetUpgradeOwed)
    }
    // #3546 A3: an activation deferred because the engine lease was held (a speed test, a
    // decode still finishing for an abandoned take) is offered again when it is released.
    // #3849: every poke re-runs every gate, so a switch deferred by gate 6c applies here too.
    engineLease.onReleased = { [weak engineCoordinator, meetingWakes] in
      engineCoordinator?.poke(.parakeetUpgradeOwed)
      // #4052: a meeting pass waiting for the engine takes its turn.
      meetingWakes.poke()
    }
    // GitHub cloud review, PR #1732: now that `engineCoordinator` exists,
    // `isDictationActive` (wired above) can read its minting state.
    engineCoordinatorForRecoveryGate = engineCoordinator
    // The picker change notifies the coordinator (it reads the live selection).
    settingsSync.onSelectedBackendChanged = { [weak engineCoordinator] in
      engineCoordinator?.poke(.settingsChanged)
    }
    // #1063 PR2 / #1171: recovery never starts on top of an in-flight switch.
    recoveryCoordinator.isEngineSwitching = { [weak engineCoordinator] in
      engineCoordinator?.isSwitching ?? false
    }
    // #1171 — after a recovery scan finishes (engine free again), poke the
    // coordinator so an engine switch deferred while recovery held the engine applies.
    recoveryCoordinator.onRecoveryComplete = { [weak engineCoordinator] in
      engineCoordinator?.poke(.recoveryComplete)
    }

    // §3.4 wake-up table: a completed switch/warm/setup-change may unblock a
    // recovery pass that previously yielded.
    engineCoordinator.onEngineStateChangedForRecovery = { [weak recoveryCoordinator] in
      recoveryCoordinator?.requestRecoveryRecheck()
    }
    // Rows 4/12/13/15/16/18 (via `ensureEngineWarm()`'s shared choke point) +
    // row 6 (the Whisper adapter) + row 21 (the owned
    // `RecordingSessionKernel`'s `preWarm()`) — #1741 Chunk 9: `kernelDriver`
    // and `whisperKernelDriver`, their owned kernels, and the Whisper
    // adapter all received the shared `engineMutationScope` directly at
    // THEIR OWN construction, via the factories above; no post-init
    // forwarding needed here anymore. §3.4's "active dictation ended" wake-up
    // cause still needs per-driver wiring.
    for driver in [kernelDriver, whisperKernelDriver] {
      driver.onDictationEndedForRecovery = { [weak recoveryCoordinator] in
        recoveryCoordinator?.requestRecoveryRecheck()
      }
    }
    // Row 7: Parakeet's idle-unload choke point. #1741 Chunk 3 — `asrManager`
    // (whichever concrete type) already received the shared `engineMutationScope`
    // at construction, above; no post-init wiring needed here anymore.
    // Rows 9/10: Whisper Settings Remove/Download/Cancel. #1741 Chunk 4 —
    // `whisper.setupService` already received the shared `engineMutationScope`
    // at construction, via `WhisperDeliveryWiring.make(...)` above; no
    // post-init wiring needed here anymore.
    // Row 14 (#3735): the WhisperKit retirement held a claim across its
    // delete+refetch window because a recovery replay's load read those same
    // files. The Whisper migration deletes only retired CoreML files no engine
    // loads any more, and the GGUF it fetches is admitted atomically by the
    // delivery controller, so it takes no claim.
    // Row 17: Parakeet Settings Download/Cancel. #1741 Chunk 6 —
    // `modelDelivery` already received the shared `engineMutationScope` at
    // construction, above; no post-init wiring needed here anymore.
    // Rows 23/27: the Diagnostics benchmark suite (DEBUG-only surface).
    // #1741 Chunk 5 — `diagnosticsCoordinator.benchmark` already received the
    // shared `engineMutationScope` at construction, above; no post-init
    // wiring needed here anymore.

    let lastRecordingResult = LastRecordingResult()
    let backendMetadata = BackendMetadata(
      settings: settings,
      llmDiscovery: llmDiscovery,
      // The coordinator's published snapshot covers BOTH engines; the manager's
      // own flag is Parakeet-only since #1386 (cloud review P2).
      activeModelLoaded: { [engineCoordinator] in engineCoordinator.status.activeModelLoaded },
      parakeetModelLabel: { [modelDelivery] in modelDelivery.parakeetModelLabel }
    )
    // PR9 of #763: construct the lifecycle home BEFORE DictationRuntime.
    // PR-C.3: the hands-free lock flag is rehomed onto `LiveRecordingState`.
    let recordingLockedAccess = DictationLifecycleCoordinator.RecordingLockedAccess(
      get: { liveRecordingState.isRecordingLocked },
      set: { locked in liveRecordingState.isRecordingLocked = locked }
    )
    // #2787: when the abandoned decode finally returns, wake the two consumers
    // that deferred work while the engine was held — a pending engine switch
    // and a deferred crash-recovery pass.
    abandonedDecodeHold.onSettled = { [weak engineCoordinator, weak recoveryCoordinator] _ in
      // Order matters: destroy the retained stop-waiting spool BEFORE the
      // recovery recheck, or the recheck could replay it in this launch.
      recoveryCoordinator?.handleAbandonedDecodeReturned()
      engineCoordinator?.poke(.driverStateChanged)
      recoveryCoordinator?.requestRecoveryRecheck()
    }
    // #1413: ONE hold, shared by the coordinator (per-transition driver) and the
    // runtime (the app shell's launch/quit entry points). Not stored here: the
    // composition root's stored-property cap is at its limit and the runtime
    // already owns this take-scoped family.
    let otherAudioHold = OtherAudioHold(
      dependencies: OtherAudioHold.Dependencies(
        effects: otherAudioEffects,
        defaultOutputDeviceID: { AudioDeviceEnumerator.defaultOutputDeviceID() },
        store: OtherAudioHoldStore(),
        telemetry: LiveOtherAudioTelemetrySink(),
        log: { line in
          Task { await AppLogger.shared.log(line, level: .info, category: "OtherAudio") }
        },
        nowMicros: { Int(DispatchTime.now().uptimeNanoseconds / 1_000) },
        sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
        pid: ProcessInfo.processInfo.processIdentifier,
        isProcessAlive: { pid in
          // Alive AND ours: a reused pid names some other executable, and a
          // process whose path cannot be read is not a running EnviousWispr.
          guard kill(pid, 0) == 0 || errno == EPERM else { return false }
          var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
          let written = buffer.withUnsafeMutableBytes { bytes -> Int32 in
            guard let base = bytes.baseAddress else { return 0 }
            return proc_pidpath(pid, base, UInt32(bytes.count))
          }
          guard written > 0, Int(written) <= buffer.count else { return false }
          let path = String(
            decoding: buffer[..<Int(written)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
          return path.hasSuffix("/EnviousWispr")
        },
        isMeetingCapturing: { [meetingBox] in meetingBox.coordinator?.isCapturing ?? false }))
    let dictationLifecycleCoordinator = DictationLifecycleCoordinator(
      kernelDriver: kernelDriver,
      whisperKernelDriver: whisperKernelDriver,
      recordingOverlay: recordingOverlay,
      hotkeyService: hotkeyService,
      settingsSync: settingsSync,
      audioCapture: audioCapture,
      transcriptCoordinator: transcriptCoordinator,
      settings: settings,
      lastRecordingResult: lastRecordingResult,
      languageSuggestionPresenter: languageSuggestionPresenter,
      recordingLockedAccess: recordingLockedAccess,
      // #2648 — the running session's claim comes back here, on the session's
      // terminal transition, because both start methods return while the
      // recording is still running. #2787: through the hold, which keeps the
      // engine claimed if the session's vendor decode is still running.
      releaseEngineClaim: { [abandonedDecodeHold] token in
        abandonedDecodeHold.releaseFromDictation(token)
      },
      otherAudioHold: otherAudioHold
    )
    dictationLifecycleCoordinator.install()
    // #1171 — every pipeline state change pokes the coordinator: non-terminal
    // transitions refresh engine status; terminals apply a deferred switch.
    dictationLifecycleCoordinator.onEngineRelevantStateChange = { [weak engineCoordinator] in
      engineCoordinator?.poke(.driverStateChanged)
    }

    // PR8 of #763: heart-path event-routing home. PR10: also constructs
    // HotkeyController / RecordingStarter / RecordingFinalizer internally.
    let dictationRuntime = DictationRuntime(
      audioCapture: audioCapture,
      asrManager: asrManager,
      kernelDriver: kernelDriver,
      whisperKernelDriver: whisperKernelDriver,
      settings: settings,
      permissions: permissions,
      recordingOverlay: recordingOverlay,
      hotkeyService: hotkeyService,
      lastRecordingResult: lastRecordingResult,
      languageSuggestionPresenter: languageSuggestionPresenter,
      dictationLifecycleCoordinator: dictationLifecycleCoordinator,
      otherAudioHold: otherAudioHold,
      recoveryCoordinator: recoveryCoordinator,
      recordingLockedAccess: recordingLockedAccess,
      // #2648 — the record-start paths claim the shared resource as a DICTATION
      // and can claim as nothing else: the holder is bound here, not at the call
      // site.
      engineAdmission: .live(lease: engineLease, as: .dictation),
      resolveActiveCaptureBackend: { [weak dictationLifecycleCoordinator] in
        dictationLifecycleCoordinator?.activeCaptureBackend()
      },
      resolveActiveTelemetryTarget: { [weak dictationLifecycleCoordinator] in
        dictationLifecycleCoordinator?.activeTelemetryTarget()
      },
      isCurrentSession: { [weak dictationLifecycleCoordinator] sessionID in
        dictationLifecycleCoordinator?.isCurrentSession(sessionID) ?? false
      },
      // #1171 — the start-of-recording safety check drives the SELECTED engine to
      // ready (the coordinator owns the single-flight switch + warm) before
      // recording, and gates a press during an in-flight switch.
      ensureSelectedReadyForPress: { [weak engineCoordinator] in
        await engineCoordinator?.ensureSelectedReadyForPress() ?? .notReady
      },
      isEngineSwitching: { [weak engineCoordinator] in engineCoordinator?.isSwitching ?? false },
      beginMinting: { [weak engineCoordinator] in engineCoordinator?.beginMinting() },
      // #1386 PR-2c (founder): a press on a removed/never-installed model shows
      // the honest not-installed pill — and a model MID-REMOVAL counts as
      // removed (founder: no new dictations during a removal drain; the drain's
      // first instants can still read installed+ready). Defaults OPEN on a
      // missing authority.
      isSelectedModelInstalled: { [weak engineCoordinator, weak setup] in
        guard let engineCoordinator else { return true }
        if engineCoordinator.status.selected == .whisper,
          setup?.whisperSetup.isRemoving == true
        {
          return false
        }
        return engineCoordinator.status.selectedInstalled
      },
      endMinting: { [weak engineCoordinator] in engineCoordinator?.endMinting() },
      // #3546 A3: a press during the in-session Ultra activation gets the upgrade pills.
      isActivatingParakeetUpgrade: { [weak engineCoordinator] in
        engineCoordinator?.isActivatingParakeetUpgrade ?? false
      },
      // #4069: the coordinator is assigned to the box later in this init, so read it live.
      isDictationOffForMeeting: { [settings, meetingBox] in
        meetingBox.refusesDictation(turnedOff: settings.meetingTurnsOffDictation)
      }
    )

    // PR-B.3 of #763: menu bar surface home.
    // **Built HERE rather than at its `self.quickAdd =` assignment below, because the menu-bar
    // action needs it (#2412) and that assignment is a hundred lines further on.** A closure cannot
    // reach it there: `[weak self]` is illegal while `self` is still being initialised, and
    // `[weak quickAdd]` names nothing yet.
    //
    // Every dependency it takes already exists well above this line — `customWordsCoordinator`
    // (:141), `vocabularyPackManager` (:150), `hotkeyService` (:438) — so this is a reorder, not a
    // new dependency.
    //
    // The alternative was a settable seam on `MenuBarController`, and it is worse for a reason this
    // issue is about: it makes the wiring optional at the type level, so "the menu item does nothing
    // because nobody set the seam" becomes a state that compiles. A menu entry that silently does
    // nothing is exactly the failure #2412 exists to route around.
    let quickAdd = QuickAddWiring(
      hotkeyService: hotkeyService,
      customWords: customWordsCoordinator,
      packManager: vocabularyPackManager,
      presentationEffects: presentationEffects,
      settings: settings)

    // #3106: Paste and Copy Last Dictation. One action owns the menu item and both chords; the
    // chords are wired here, and installing `onPasteLast` / `onCopyLast` is what lets the hotkey
    // service register them at all.
    let openPermissionsWindow: @MainActor () -> Void = {
      navigationCoordinator.request(.appSettings(.permissions))
      appWindowCoordinator.showWindow()
    }
    let lastDictationAction = LastDictationAction.live(
      transcripts: transcriptCoordinator,
      liveRecordingState: liveRecordingState,
      settings: settings,
      application: presentationEffects.application,
      openPermissions: openPermissionsWindow)
    let historyPaste = HistoryPaste.live(
      settings: settings, permissions: permissions, application: presentationEffects.application)
    hotkeyService.onPasteLastPressed = { lastDictationAction.notePasteChordPressed() }
    hotkeyService.onPasteLast = { lastDictationAction.pasteFromChord() }
    hotkeyService.onCopyLast = { lastDictationAction.copyFromChord() }

    let menuBarController = MenuBarController(
      liveRecordingState: liveRecordingState,
      backendMetadata: backendMetadata,
      sparkleUpdateController: sparkleUpdateController,
      settings: settings,
      permissions: permissions,
      actions: MenuBarActions(
        addSelectedWord: { quickAdd.beginFromMenuBar(selection: $0, context: $1) },
        continueOnboarding: { appWindowCoordinator.openOnboardingWindow() },
        openMainWindow: {
          navigationCoordinator.request(.history)
          appWindowCoordinator.showWindow()
        },
        openHelpCenter: {
          if let url = URL(string: HelpCenter.rootURL) { NSWorkspace.shared.open(url) }
        },
        // #3454: the Settings dropdown's own titles ("<name> · <connection>"), read as the menu opens.
        microphoneChoices: {
          audioDeviceList.availableInputDevices.map { device in
            MicrophoneMenuChoice(
              uid: device.uid,
              title: MicrophoneDevicePicker.optionTitle(
                for: device, transportToken: AudioDeviceEnumerator.transportLabel(for: device.id)))
          }
        },
        isMicrophoneConnected: { MicrophoneChoiceValidation.isSelectable(uid: $0) },
        openTranscribeFile: {
          navigationCoordinator.request(.transcribeFile)
          appWindowCoordinator.showWindow()
        },
        openPermissions: openPermissionsWindow,
        // #3438: evaluated live as the menu is built (the monitor is bound later; until it is,
        // nothing shows).
        polishSetupWarning: { [polishSetupMonitorHolder] in
          guard let monitor = polishSetupMonitorHolder.monitor else { return nil }
          _ = monitor.currentContext()
          return monitor.shows(.menu) ? monitor.promptSubject : nil
        },
        openAIPolish: { [polishSetupMonitorHolder] subject in
          // The menu line is the only way here; report what it showed when it was built.
          polishSetupMonitorHolder.monitor?.recordPrompt(.menu, .finishSetup, subject: subject)
          navigationCoordinator.request(.aiPolish)
          appWindowCoordinator.showWindow()
        },
        toggleRecording: { await dictationRuntime.toggleRecording(source: .menuBar) },
        meetingPhase: { [meetingBox] in meetingBox.coordinator?.phase },
        requestMeetingStart: { [meetingBox] in
          await meetingBox.startFlow?.requestStart(from: .menu)
        },
        stopMeeting: { [meetingBox] in await meetingBox.coordinator?.stop() },
        meetingMenuFacts: { [meetingBox] in
          guard let coordinator = meetingBox.coordinator else { return nil }
          return MeetingsPresentation.MenuFacts(
            phase: coordinator.phase, processing: coordinator.processing,
            callSound: coordinator.callSoundStatus,
            waitingOnSummary: coordinator.passWaitsOnSummary)
        },
        showMeeting: { [weak transcriptCoordinator] meetingID in
          transcriptCoordinator?.showRecordings(meetingID: meetingID)
          navigationCoordinator.request(.history)
          appWindowCoordinator.showWindow()
        },
        quit: { NSApp.terminate(nil) },
        lastDictation: { [weak transcriptCoordinator] in
          transcriptCoordinator?.lastPasteableDictation()
        },
        pasteLastDictation: { rowID, target in
          lastDictationAction.pasteFromMenu(rowID: rowID, target: target)
        }
      )
    )

    // #1451: App Translocation recovery limb, driven from the launch sequence.
    let applicationRelocationCoordinator = ApplicationRelocationCoordinator.live(
      presentation: presentationEffects, relauncher: relocationRelauncher)

    // #1480: Bluetooth cold-start card. Single decision owner; ingress facts come
    // from AppLifecycleCoordinator + settings.onChange. Wiring lives in `.live(...)`;
    // built before AppLifecycleCoordinator (which stores it).
    let bluetoothAwarenessPresenter = BluetoothAwarenessPresenter.live(
      overlay: recordingOverlay,
      settings: settings,
      liveRecordingState: liveRecordingState,
      navigationCoordinator: navigationCoordinator,
      appWindowCoordinator: appWindowCoordinator
    )
    bluetoothAwarenessPresenterHolder.presenter = bluetoothAwarenessPresenter

    // #3289 §8b: is the app working, for the idle-memory sample. A dictation is in flight from
    // arming to its terminal (the drivers' session config, which outlives an `.error` the pipeline
    // may publish early); anything else that works holds the engine lease (a file import until its
    // work exits, which outlasts Stop; crash recovery; an abandoned decode), and a running import
    // counts from Start, before its claim. The word check's idle
    // timer asks a narrower question, work that uses THAT check (`inFlightWorkNeedsWordCheck`).
    let isWorkInFlight: @MainActor () -> Bool = {
      [weak kernelDriver, weak whisperKernelDriver, weak engineLease] in
      kernelDriver?.currentSessionConfig != nil
        || whisperKernelDriver?.currentSessionConfig != nil
        || engineLease?.isBusy == true
        // An import is running from Start, including while it readies the engine before it claims
        // the lease (#3289 final review).
        || fileImportCoordinatorForGates?.isRunning == true
    }
    // #3289 §8b: one idle-memory sample per launch. Its task keeps it alive until it sends.
    let idleMemoryObserver = IdleMemoryObserver(
      isWorkInFlight: isWorkInFlight,
      // Every engine claim, plus every Transcribe a File action (choose, Start, Stop, start over,
      // Clean it again move its `generation`), including a Start that ends before its claim. Both
      // only increase, so any activity changes the sum.
      workEpoch: { [weak engineLease] in
        (engineLease?.admissionEpoch ?? 0) &+ (fileImportCoordinatorForGates?.generation ?? 0)
      },
      usageMetricsOn: { [settings] in settings.shareUsageMetrics },
      wordCheckState: { [weak checkerEligibility] in
        (
          checkerEligibility?.wordCheck?.isLoadedForTelemetry ?? false,
          checkerEligibility?.wordCheck?.isWantedForTelemetry ?? false
        )
      },
      emit: { [asrManager, kernelDriver, whisperKernelDriver] sample in
        TelemetryService.shared.appIdleMemory(
          footprintMB: sample.footprintMB, minutesSinceLaunch: sample.minutesSinceLaunch,
          wordCheckLoaded: sample.wordCheckLoaded, wordCheckWanted: sample.wordCheckWanted,
          // #3546 §3.7 T1: the active engine's loaded model, nil when none is loaded.
          model: asrManager.activeBackendType == .whisper
            ? whisperKernelDriver.servingModelAttribution
            : kernelDriver.servingModelAttribution)
      })
    idleMemoryObserver.start()
    idleMemoryObserverForSettings = idleMemoryObserver

    // PR-B.4 of #763: process-lifecycle home. Constructed last. It receives the
    // 10 specific homes it reads.
    let previousApplicationTracker = PreviousApplicationTracker()
    let appLifecycleCoordinator = AppLifecycleCoordinator(
      wheelScrollSmoother: WheelScrollSmoother(monitor: scrollWheelMonitor),
      previousApplicationTracker: previousApplicationTracker,
      settings: settings,
      permissions: permissions,
      keychainManager: keychainManager,
      standingSnapshotBuilder: standingSnapshotBuilder,
      contactsImportCoordinator: contactsImportCoordinator,
      aiAvailability: aiAvailability,
      audioCapture: audioCapture,
      asrManager: asrManager,
      kernelDriver: kernelDriver,
      whisperKernelDriver: whisperKernelDriver,
      setup: setup,
      dictationRuntime: dictationRuntime,
      dictationLifecycleCoordinator: dictationLifecycleCoordinator,
      liveRecordingState: liveRecordingState,
      menuBarController: menuBarController,
      appWindowCoordinator: appWindowCoordinator,
      hotkeyService: hotkeyService,
      applicationRelocationCoordinator: applicationRelocationCoordinator,
      bluetoothAwarenessPresenter: bluetoothAwarenessPresenter,
      onboardingProgress: onboardingProgress,
      transcriptionCheckpointStore: transcriptionCheckpointStore,
      batchDecodeFaultController: batchDecodeFaultController,
      whisperMemoryPressure: whisperMemoryPressure,
      // #996: each real transition into `.recording` cancels a live edit watch.
      // #3242: and pre-loads the word check so the take's check finds it ready.
      // #3988: and restarts the take's local polish engine if something outside
      // the app stopped it, so the next dictation is polished again.
      onRecordingStarted: {
        [
          weak learnFromEdits, weak checkerEligibility, weak kernelDriver,
          weak whisperKernelDriver, localPolishRuntimes
        ] in
        learnFromEdits?.recordingStarted()
        // The take's frozen provider (set at arming), never the mutable setting.
        guard
          let provider = kernelDriver?.currentSessionConfig?.llmProvider
            ?? whisperKernelDriver?.currentSessionConfig?.llmProvider
        else { return }
        checkerEligibility?.wordCheck?.recordingStarted(
          needsWordCheckForRecording: LearnedWordCheckerEngine(provider: provider) == nil)
        localPolishRuntimes.runtime(for: provider)?.recordingStarted()
      }
    )

    #if DEBUG
      appLifecycleCoordinator.qualificationChildTrap = {
        [coordinator = egOneRuntime.serverCoordinator] in
        await coordinator.qualificationTrapOwnedReadyChild()
      }
    #endif

    self.navigationCoordinator = navigationCoordinator
    self.diagnosticsCoordinator = diagnosticsCoordinator
    #if DEBUG
      self.pillPreviewController = PillPreviewController(
        presenter: recordingOverlay,
        isPipelineBusy: { [liveRecordingState] in
          liveRecordingState.isDictationActive || liveRecordingState.pipelineState.isActive
        },
        overlayIsEmpty: { [recordingOverlay] in
          recordingOverlay.renderModel.state.presentation == nil
        })
    #endif
    self.recoveryCoordinator = recoveryCoordinator
    self.languageSuggestionPresenter = languageSuggestionPresenter
    self.updateCoordinatorHolder = updateCoordinatorHolder
    self.settingsKeyMonitor = settingsKeyMonitor
    self.sparkleUpdateController = sparkleUpdateController
    self.updateTriggerCoordinator = updateTriggerCoordinator
    // #2648 — Transcribe a File. Built here because the job outlives every view
    // that shows it: leaving the page and coming back has to land on whatever
    // the run has reached.
    //
    // The runner is constructed with the same polish handles live dictation and
    // crash recovery use, so an imported part is polished by the same engine,
    // under the same key, as anything else this app produces.
    let fileImportRunner = FileImportRunner(
      keychainManager: keychainManager,
      egOneRuntime: egOneRuntime,
      s1MiniRuntime: s1MiniRuntime,
      // #2648, cloud review: the SAME output-safety classifier live dictation
      // and crash recovery get. Without it an imported part polished by Apple
      // Intelligence silently loses the classifier-aware output filter, even
      // when the classifier prewarmed successfully.
      outputClassifierHolder: outputClassifierHolder,
      checkerSelectionProvider: { [checkerEligibility] provider, language in
        await checkerEligibility.selection(provider: provider, language: language)
      })
    fileImportRunnerForGates = fileImportRunner
    // #2648: the health probe asks the lease, not the settings sync, because
    // the question is "is the ONE inference slot occupied" and every workload
    // that can occupy it takes this claim. `isBusy` had no production reader
    // when the lease shipped; file import is what made the gap live, so it is
    // wired here rather than deferred again. Codex confirming round.
    egOneRuntime.isSharedEngineBusy = { [weak engineLease] in engineLease?.isBusy ?? false }
    s1MiniRuntime.isSharedEngineBusy = { [weak engineLease] in engineLease?.isBusy ?? false }
    egOneRuntime.sharedEngineAdmissionEpoch = { [weak engineLease] in
      engineLease?.admissionEpoch ?? 0
    }
    s1MiniRuntime.sharedEngineAdmissionEpoch = { [weak engineLease] in
      engineLease?.admissionEpoch ?? 0
    }

    // #4052: one readiness drive and one unload-timer pair for the two workloads that borrow the
    // selected engine under the lease: Transcribe a File and EnviousMeet's final pass.
    //
    // The SAME authority a record press uses, so "is the engine the user
    // picked ready" has one answer in the app rather than two.
    //
    // **`.notReady` is not a refusal on its own, and this is the import's own
    // cold-press path.** `ensureSelectedReadyForPress` deliberately leaves a
    // SELECTED-AND-ACTIVE BUT COLD engine to dictation's cold-press path,
    // which warms it on the next press. Import has no next press, so it read
    // that answer as "no" and refused a file whose engine only needed loading
    // — reachable through the ordinary memory-saving unload setting. Found by
    // Codex. `load()`'s postcondition is readiness, not merely that the call
    // returned, so a warm that fails still refuses.
    let ensureSelectedEngineReady: @MainActor () async -> FileImportCoordinator.EngineReadiness = {
      [weak engineCoordinator, activeEngine] in
      guard let engineCoordinator else { return .notReady }
      switch await engineCoordinator.ensureSelectedReadyForPress() {
      case .ready: return .ready
      case .notInstalled: return .notInstalled
      case .notReady:
        guard (try? await activeEngine.load()) != nil else { return .notReady }
        return await activeEngine.isLoaded() ? .ready : .notReady
      }
    }
    // **The disarm/re-arm pair, handed over as a pair.** A dictation minutes
    // earlier arms a timer under the user's model-unload setting, and its
    // mutation gate does not consult `EngineLease`, so it could fire mid-import
    // and clear the model the decoder is running on. Each engine arms its OWN
    // timer, so both are named on both sides; `ParakeetEngineAdapter` forwards
    // to `ASRManager.noteTranscriptionComplete`, which is why going through
    // the adapters covers both engines rather than one of them twice.
    // Idempotent, so both are always touched rather than whichever looks
    // active.
    let disarmEngineTimers: @MainActor () -> Void = { [kernelDriver, whisperKernelDriver] in
      kernelDriver.cancelPendingEngineUnload()
      whisperKernelDriver.cancelPendingEngineUnload()
    }
    let rearmEngineTimers: @MainActor () -> Void = { [kernelDriver, whisperKernelDriver, settings] in
      kernelDriver.applyEngineUnloadPolicy(settings.modelUnloadPolicy)
      whisperKernelDriver.applyEngineUnloadPolicy(settings.modelUnloadPolicy)
    }

    let fileImportCoordinator = FileImportCoordinator(
      decode: { url in try await AudioFileDecoder.decode(url: url) },
      // **The user's locked language reaches ASR, not just the cleanup.** Cloud
      // review found `.default` here: Whisper uses `options.language` to turn
      // auto-detection OFF and Parakeet uses it for its language/script filter,
      // so a locked non-English recording could be recognised in the wrong
      // script before post-processing ever saw it.
      // **Through `ActiveEngineOperation`, which is the ONE door for "whichever
      // speech engine is active".** Calling `asrManager.transcribe` directly
      // reached Parakeet and only Parakeet: with All Languages selected it threw
      // `ASRManagerNotOwnedError`, because Whisper does not live in the
      // manager.
      //
      // No load here: `ensureEngineReady` above owns warming, and it runs before
      // the claim precisely so the switch it may trigger is not deferred by the
      // claim. A second loader here would be a second answer to the same
      // question, which is the shape that produced this feature's first defect.
      transcribe: { [activeEngine, settings] samples, onProgress, onInferenceEntered in
        var options = TranscriptionOptions.default
        if case .locked(let code) = settings.languageMode { options.language = code }
        // The engine's own language answer travels with the words. Reducing this
        // to `.text` threw away the better half: the cleanup chain's ladder
        // prefers what the engine heard over what a text identifier guesses from
        // the ASR output.
        // #2809: widened to the full ASRResult so `wordTimings`/`wordTimingCoverage` reach
        // the coordinator — the only consumer today is the speaker step's telemetry.
        // #2918: the Working card's transcribing bar. Installed for THIS call and cleared
        // on both exits, so a dictation that follows never inherits the import's sink.
        await activeEngine.setTranscriptionProgressObserver(onProgress)
        do {
          // #3546 §3.7 T1: the run's own inference observation travels with this call.
          let result = try await activeEngine.transcribe(samples, options, onInferenceEntered)
          await activeEngine.setTranscriptionProgressObserver(nil)
          return result
        } catch {
          await activeEngine.setTranscriptionProgressObserver(nil)
          throw error
        }
      },
      // #2809: the dormant speaker step. Loads the bundled models fresh per call (see
      // `SpeakerLabeler`) and never touches the network — a phase-2 limb that runs after
      // ASR on the same PCM, bounded and cancellable, with no UI signal on any outcome.
      speakerLabeler: { samples, durationSeconds in
        await SpeakerLabeler().run(samples: samples, durationSeconds: durationSeconds)
      },
      emitSpeakerTelemetry: { outcome, durationSeconds, analysisMs, wordTimingCoverage in
        TelemetryService.shared.trackFileImportSpeakers(
          outcome: outcome, durationSeconds: durationSeconds, analysisMs: analysisMs,
          wordTimingCoverage: wordTimingCoverage)
      },
      emitTurnTelemetry: { outcome, turnCount, fallbackTurnCount in
        TelemetryService.shared.trackFileImportTurns(
          outcome: outcome, turnCount: turnCount, fallbackTurnCount: fallbackTurnCount)
      },
      emitRenameTelemetry: { outcome in
        TelemetryService.shared.trackFileImportRename(outcome: outcome)
      },
      emitSpeakerRetryTelemetry: { outcome in
        TelemetryService.shared.trackFileImportSpeakerRetry(outcome: outcome)
      },
      emitTurnsDisplayedTelemetry: {
        TelemetryService.shared.trackFileImportTurnsDisplayed(screen: .wizard)
      },
      // #3069: which engine, whether it and the configured polisher succeeded.
      emitRunTelemetry: {
        outcome, backend, asrModel, durationSeconds, asrOutcome, polishOutcome, provider, model in
        TelemetryService.shared.trackFileImportCompleted(
          outcome: outcome, asrBackend: backend, model: asrModel,
          durationSeconds: durationSeconds, asrOutcome: asrOutcome, polishOutcome: polishOutcome,
          polishProvider: provider, polishModel: model)
      },
      // #3069: same `.asrFailed` category and fingerprint dictation's own ASR failures use
      // (one engine defect, one Sentry issue), tagged `stage: "file_import"` so it is
      // filterable separately in the Sentry UI.
      captureASRFailure: { error, backend in
        SentryBreadcrumb.captureError(
          SentryCaptureBoundaryError.normalizingTranscriptionFailure(error),
          category: .asrFailed, stage: "file_import", extra: ["backend": backend.rawValue])
      },
      // The third workload, claiming the same one-slot engine as a dictation and
      // a crash replay.
      engineAdmission: .live(lease: engineLease, as: .fileImport),
      // The SAME lookup the polish-runtime reconciliation uses, so the page's
      // privacy line and the eviction rule cannot disagree about one model. An
      // unknown model answers `nil`, read here as NOT remote, which matches the
      // provider-only classification this replaced and never over-claims a
      // cloud upload the user did not make.
      // Three answers, passed through. `nil` means the daemon has not been
      // asked, which the page must not read as "runs here".
      // #2772: the IMPORT's polisher, not dictation's. This answers the privacy line on
      // the wizard's own page, so reading dictation's provider here would promise local
      // processing about an engine this import is not using. Same resolver the freeze
      // reads, so the line and the run cannot disagree.
      polishOllamaLocalityNow: { [settings, ollamaRemoteness] in
        settings.effectiveFileImportLLMProvider == .ollama
          ? ollamaRemoteness(settings.effectiveFileImportLLMModel) : false
      },
      refreshOllamaFacts: { [ollamaSetup = setup.ollamaSetup] in
        await ollamaSetup.refreshDownloadedModels()
      },
      // Shared with EnviousMeet's final pass (#4052); reasons at their definitions above.
      disarmEngineTimers: disarmEngineTimers,
      rearmEngineTimers: rearmEngineTimers,
      engineSelectionSettled: { [settings, asrManager] in
        settings.selectedBackend == asrManager.activeBackendType
      },
      ensureEngineReady: ensureSelectedEngineReady,
      // The same three retries a finished dictation fires
      // (`DictationLifecycleCoordinator` on its terminal), because an import
      // blocks the same three things: an engine switch deferred by gate 6b, an
      // Ollama eviction deferred by the pinned model, and an EG-1 deactivation
      // deferred by the pinned runtime. Without this a settings change made
      // during a long import stayed pending until something unrelated happened
      // to poke the same paths.
      onEngineReleased: {
        [
          weak engineCoordinator, weak recoveryCoordinatorForEngineMutationScope, settings,
          asrManager, localPolishRuntimes
        ] in
        // #3105: THIS run's server hold is taken synchronously, so a later
        // import's hold can never be the one released, and the forced reconcile
        // waits for the release rather than being deferred behind it.
        let releaseHold = localPolishRuntimes.releaseImportHold()
        // #3289: the job is over, so its cached checker selections go; the word check's model is
        // then held only by the runtime (idle timer) and by any late answer still returning.
        fileImportRunner.releaseCheckerSelections()
        engineCoordinator?.poke(.driverStateChanged)
        settingsSync.retryDeferredOllamaEviction(settings: settings)
        settingsSync.retryDeferredOutputClassifierRelease(settings: settings)
        Task { @MainActor in
          await releaseHold?.value
          // #2772: FORCED. An import that started its own bundled polisher armed no
          // pending flag, so the unforced call returned without reconciling and the
          // import's engine stayed resident in place of dictation's.
          settingsSync.retryDeferredEGOneDeactivation(
            settings: settings, forceReconciliation: true)
        }
        // **Recovery needs its OWN wake.** A poke that finds the selected and
        // active engines already matching returns without reaching recovery, so
        // a scan that released its mutation gate because an import held the
        // engine would wait for an unrelated trigger, or for the next launch.
        // Same call the engine-mutation scope already uses as its wake. Found by
        // Codex; timing not reproduced, and fixed because it is one line and its
        // failure is silent.
        recoveryCoordinatorForEngineMutationScope?.requestRecoveryRecheck()
      },
      // The user's words, read LIVE at Start rather than held from launch: the
      // propagator is the one place that knows the current vocabulary, and an
      // import started after the user adds a word should use it.
      // The wizard's steps WRITE settings when the user picks, so freezing
      // settings here freezes exactly what the user chose on those screens.
      beginRun: {
        [settings, customWordsPropagator, localPolishRuntimes, kernelDriver, whisperKernelDriver]
        in
        let snapshot = FileImportSettingsFreeze.snapshot(settings: settings)
        fileImportRunner.freeze(settings: snapshot, vocabulary: customWordsPropagator.corrector)
        // #3289: Start and Clean it again both come through here, after the claim; preload the word
        // check now for a run whose FROZEN engine has no checker of its own, so the first part finds
        // it loading or ready. Opening the page or a refused claim never reaches this line.
        checkerEligibility.wordCheck?.fileImportStarted(
          needsWordCheck: LearnedWordCheckerEngine(
            provider: LLMProvider(rawValue: snapshot.llmProvider) ?? .none) == nil)
        var configuration = FileImportSettingsFreeze.configuration(
          for: snapshot,
          ollamaModelIsRemote: snapshot.llmProvider == LLMProvider.ollama.rawValue
            ? ollamaRemoteness(snapshot.llmModel) : false)
        // #3546 §3.7 T1: the frozen engine's serving model, read at the same freeze.
        configuration.asrModel = FileImportSettingsFreeze.frozenASRModel(
          backend: configuration.backendType,
          parakeetServing: kernelDriver.servingModelAttribution,
          whisperServing: whisperKernelDriver.servingModelAttribution,
          whisperValidated: whisperKernelDriver.requestedModelAttribution)
        // #2772: **the import starts its OWN bundled polisher.**
        //
        // Since the import's polisher is chosen independently of dictation's, EG-1 can be
        // this run's engine while dictation is on Gemini — and `PipelineSettingsSync`
        // deliberately activates dictation's engine only, because these two servers compete
        // for one resource and starting both is the conflict its ordering exists to
        // prevent. Without this call the run would ask a stopped server to polish and every
        // part would come back raw, silently. Found by chunk-2 review; the first attempt
        // widened that reconciler to a union and only widened its STOP half, which bought
        // nothing.
        //
        // Ordered AFTER the freeze on purpose: the configuration names which server this
        // run depends on, `pinnedLocalProvider()` reports it for as long as the run holds
        // it, and `onEngineReleased` reconciles back to dictation's selection at the end.
        // Idempotent, so a run whose engine is already the resident one costs nothing.
        return configuration
      },
      // #2772: AWAITED, not fired and forgotten. `activateAndProbe` returns the task that
      // brings the server up; discarding it let the first part reach a server that was
      // still starting. Measured in Live UAT 2026-09-10: EG-1 requested, skipped `notReady`
      // after 0.2ms, `Local polish server ready` immediately afterwards, user got raw words
      // with nothing on screen saying why.
      //
      // Only the BUNDLED servers are prepared here. Ollama is the user's own process and
      // the cloud providers have nothing on this Mac to start, which is the same set
      // `localPolishProvider` already names for the eviction pin.
      prepareLocalPolish: { [localPolishRuntimes] configuration in
        guard let localPolish = configuration.localPolishProvider else { return true }
        // A nil activation is a refusal before the server is even asked: another session
        // pins the engine, or an activation blocker stands. Red after the probe is the server
        // itself not coming up. Either way the cleanup is refused rather than run against a
        // missing endpoint, which the polish step would read as a silent skip.
        guard let runtime = localPolishRuntimes.runtime(for: localPolish),
          let activation = runtime.activateAndProbe()
        else { return false }
        await activation.value
        // The ENDPOINT, not `health`. The import already holds the engine lease here, so the
        // activation's probe sees the engine busy and skips on purpose, leaving `health` at
        // whatever the last probe said; a server that just came up after an earlier red
        // verdict would be refused on stale advice. The endpoint is what the run will use.
        guard await runtime.activeEndpoint() != nil else { return false }
        return await localPolishRuntimes.holdForImport(localPolish)
      },
      // #2772 finding 11: the third writer of History, beside dictation and crash replay.
      // Through the COORDINATOR rather than the store, so the row appears immediately —
      // writing to disk alone would leave History showing the old list until the next
      // launch, which is indistinguishable from not saving at all.
      saveToHistory: { [transcriptCoordinator] transcript in
        try await transcriptCoordinator.saveAndShow(transcript)
      },
      // The cleaned write, which may only update a row that is still there. History is
      // reachable throughout a cleanup, so a deletion between the two writes has to stand.
      updateHistoryRow: { [transcriptCoordinator] transcript in
        try await transcriptCoordinator.updateExistingRow(transcript)
      },
      // The speaker-fields write (#2810 addendum §3 E) — reads the row's CURRENT state at
      // call time, so it can never clobber a rename that landed while cleanup was running.
      mergeSpeakerFields: { [transcriptCoordinator] id, analysis, turns in
        try await transcriptCoordinator.mergeSpeakerFields(id: id, analysis: analysis, turns: turns)
      },
      // The rename write (#2811, phase 4) — same underlying method, an explicit rename pair
      // this time.
      writeExplicitRename: { [transcriptCoordinator] id, analysis, turns, explicitRename in
        try await transcriptCoordinator.mergeSpeakerFields(
          id: id, analysis: analysis, turns: turns, explicitRename: explicitRename)
      },
      currentHistoryRow: { [transcriptCoordinator] id in transcriptCoordinator.currentRow(id: id) },
      historyRowExists: { [transcriptCoordinator] id in transcriptCoordinator.hasRow(id: id) },
      processParts: { [fileImportRunner] parts, language, onOutcome in
        try await fileImportRunner.process(parts: parts, engineLanguage: language, onOutcome: onOutcome)
      })
    // History announces a deleted row; the wizard drops the retry audio it holds for that
    // row (#2811, cloud review of PR #2846). Late-bound because History's coordinator is
    // built first.
    transcriptCoordinator.onRowDeleted = { [weak fileImportCoordinator] id in
      fileImportCoordinator?.noteHistoryRowDeleted(id)
    }
    // And History asks whether a row's import is still cleaning (#2851 §3 D): the detail
    // view discloses "Not fully polished" only on a finished document.
    transcriptCoordinator.isImportInProgress = { [weak fileImportCoordinator] id in
      fileImportCoordinator?.isSettlingTurns(of: id) ?? false
    }
    fileImportCoordinatorForGates = fileImportCoordinator
    self.fileImportCoordinator = fileImportCoordinator
    // #3242: the word check never idle-unloads while a dictation that uses it is in flight, and a
    // take keeps the check its FROZEN provider selects. The drivers' session config is the in-flight
    // authority: it lives from arming to the terminal, unlike the published pipeline state (an
    // external error can show `.error` while the kernel is still processing).
    // #3289: a file import holding the engine counts too, from its claim until its work exits (which
    // outlasts Stop), with the need read from the run's FROZEN provider. Wired here, after the
    // coordinator exists, so the closure can see it.
    checkerEligibility.wordCheck?.inFlightWorkNeedsWordCheck = {
      [
        weak kernelDriver, weak whisperKernelDriver, weak fileImportCoordinator,
        weak fileImportRunner
      ] in
      WordCheckRuntime.workNeedsWordCheck(
        dictationProviders: [
          kernelDriver?.currentSessionConfig, whisperKernelDriver?.currentSessionConfig,
        ]
        .compactMap { $0?.llmProvider },
        importHoldsEngine: fileImportCoordinator?.isEngineHeld == true,
        importProvider: fileImportRunner?.frozenLLMProvider)
    }
    #if DEBUG
      self.debugImportDoor = DebugImportDoor(
        coordinator: fileImportCoordinator,
        // The screen's gate, composed from the same coordinators the screen reads; the
        // door has no editor and so no unsaved-key draft.
        polishReadiness: {
          [
            settings, keychainManager, llmDiscovery, localPolishRuntimes, aiAvailability, setup,
            savedKeyPresence
          ] in
          let provider = settings.effectiveFileImportLLMProvider
          // The probes the screen runs on every appearance, through the same owner.
          await FileImportPolishGate.armImport(
            provider, trigger: "import_door", setup: setup, availability: aiAvailability)
          // The probe suspended; a provider changed underneath it would be judged with
          // another engine's facts. Re-read and defer rather than answer for the wrong one.
          guard provider == settings.effectiveFileImportLLMProvider else {
            return .blocked(.checking)
          }
          return FileImportPolishGate.readiness(
            provider: provider,
            savedKey: FileImportPolishGate.savedKey(for: provider, keychain: keychainManager),
            hasUnsavedKeyDraft: false,
            importOllamaModel: settings.fileImportLLMProvider == nil
              ? settings.ollamaModel : settings.fileImportOllamaModel,
            llmDiscovery: llmDiscovery, localPolishRuntimes: localPolishRuntimes,
            aiAvailability: aiAvailability, setup: setup, savedKeyPresence: savedKeyPresence)
        })
      // #3765: every closure reads the app's own owner at request time; none caches.
      let driverFor: @MainActor (ASRBackendType) -> KernelDictationDriver = {
        [kernelDriver, whisperKernelDriver] backend in
        backend == .whisper ? whisperKernelDriver : kernelDriver
      }
      let devControlDictation = DevControlDictation(
        launchID: UUID(),
        control: DevControlDictation.Control(
          activeBackend: { [engineCoordinator] in engineCoordinator.status.active },
          driverState: { driverFor($0).state },
          readiness: { driverFor($0).engineReadiness },
          continuingTakeID: { driverFor($0).continuingSessionID },
          lastTakeID: { driverFor($0).lastTakeID },
          terminalFacts: { DevControlDictation.TerminalFacts.of(driverFor($0), takeID: $1) },
          start: { [dictationRuntime] in await dictationRuntime.toggleRecording(source: .programmatic) },
          stop: { [dictationRuntime] in await dictationRuntime.devControlUserStop() },
          cancel: { [dictationRuntime] in
            await dictationRuntime.cancelRecording(trigger: .cancelButton)
          },
          frontApp: .live))
      // Before the door can admit a start, so no take's terminal is missed.
      dictationLifecycleCoordinator.devControlSessionEndedWithoutSave = {
        [weak devControlDictation] backend, ending in
        devControlDictation?.sessionEndedWithoutSave(backend, ending)
      }
      dictationLifecycleCoordinator.devControlSessionTerminalAccepted = {
        [weak devControlDictation] backend, takeID in
        devControlDictation?.sessionTerminalAccepted(backend, takeID)
      }
      self.devControlDoor = DevControlDoor(
        dispatcher: DevControlDispatcher(
          settings: settings,
          writeContext: DevControlSettings.WriteContext(
            modelCatalog: { [llmDiscovery] in
              DevControlSettings.ModelCatalog(
                provider: llmDiscovery.stateProvider, models: llmDiscovery.discoveredModels)
            },
            loadCachedModelCatalog: { [llmDiscovery, settings] provider, surface in
              llmDiscovery.loadCachedModels(for: provider, settings: settings, surface: surface)
            },
            connectedInputUIDs: { AudioDeviceEnumerator.allInputDevices().map(\.uid) },
            inputChannelCounts: {
              Dictionary(
                AudioDeviceEnumerator.allInputDevices().map { ($0.uid, $0.inputChannelCount) },
                uniquingKeysWith: { first, _ in first })
            },
            pillWordsCapability: { [pillAppearance] in pillAppearance.wordsCapability }),
          status: DevControlDispatcher.StatusSources(
            engineStatus: { [engineCoordinator] in engineCoordinator.status },
            isSwitching: { [engineCoordinator] in engineCoordinator.isSwitching },
            driverState: { [kernelDriver, whisperKernelDriver] backend in
              (backend == .whisper ? whisperKernelDriver : kernelDriver).state
            },
            parakeetDelivery: { [modelDelivery] in modelDelivery.parakeetState },
            whisperSetup: { [setup] in setup.whisperSetup.setupState },
            isFileImportRunning: { [fileImportCoordinator] in fileImportCoordinator.isRunning },
            savedKeyState: { [savedKeyPresence] in savedKeyPresence.state(for: $0) }),
          history: DevControlDispatcher.HistorySource(
            visibleTranscripts: { [transcriptCoordinator] in
              transcriptCoordinator.visibleTranscripts
            }),
          models: DevControlDispatcher.ModelActions(
            parakeetDownload: { [modelDelivery] in modelDelivery.resumeParakeetDownload() },
            parakeetCancel: { [modelDelivery] in modelDelivery.cancelParakeetDownload() },
            whisperDownload: { [setup] in setup.whisperSetup.downloadModel() },
            whisperCancel: { [setup] in setup.whisperSetup.cancelDownload() }),
          dictation: devControlDictation,
          credentials: CredentialWriter(
            keychainManager: keychainManager, presence: savedKeyPresence,
            discovery: llmDiscovery),
          words: customWordsCoordinator,
          meetings: DevControlMeetings(
            sources: DevControlMeetings.Sources(
              coordinator: { [meetingBox] in meetingBox.coordinator },
              startFlow: { [meetingBox] in meetingBox.startFlow },
              transcripts: { [transcriptCoordinator] in transcriptCoordinator })),
          calls: DevControlCalls(
            sources: DevControlCalls.Sources(
              coordinator: { [meetingBox] in meetingBox.callDetection }))))
    #endif
    // #3972 C4a: EnviousMeet, bootstrapped here so it lives independently of any view.
    engineCoordinator.onMintingEnded = { [meetingWakes] in meetingWakes.poke() }
    let meetingMemoryPressure = MeetingMemoryPressure()
    // #3988: the pressure a local polish engine records when something outside
    // the app stops it. Context for the notice, never a cause.
    for runtime in [localPolishRuntimes.egOne, localPolishRuntimes.s1Mini] {
      runtime.memoryPressureLevel = { [weak meetingMemoryPressure] in
        meetingMemoryPressure.map { pressure in
          // Exhaustive, so a new level must be mapped here, never defaulted.
          switch pressure.level {
          case .normal: OutsideStopContext.MemoryPressure.normal
          case .warning: .warning
          case .critical: .critical
          }
        }
      }
    }
    // #3973, #4105: EnviousMeet's live words run on the engine and language the user chose
    // (Apple's meeting module or the Universal engine), frozen at each Start, never a download
    // and never Apple's dictation module; each Universal decode waits while a dictation runs on a
    // streaming engine. One choice owner serves Start and the Live words row.
    let universalAdmitted = WhisperPreviewDeliveryWiring.makeUniversalAdmitted(
      modelDelivery: modelDelivery, settings: settings)
    let meetingLiveWordsChoice = MeetingLiveWordsChoice.Initializer(
      environment: .init(
        settings: settings,
        inventory: { await MeetingLiveWordsChoice.liveInventory(universalAdmitted: universalAdmitted) },
        appleEquivalent: MeetingLiveWordsChoice.liveAppleEquivalent))
    let meetingLiveWords = MeetingLiveWords(
      dependencies: .init(
        resolveChoice: { [meetingLiveWordsChoice] forcing in
          let resolution =
            if let forcing {
              await meetingLiveWordsChoice.resolve(forcing: forcing)
            } else {
              await meetingLiveWordsChoice.materializeIfUnset()
            }
          await AppLogger.shared.log(
            "MEETING_LIVE_WORDS choice \(MeetingLiveWordsChoice.logDescription(resolution))"
              + (forcing.map { " forced=\($0.rawValue)" } ?? ""),
            category: "Meetings")
          return resolution
        },
        resolveApple: { tag in await ApplePreviewEngineResolver.resolveMeeting(languageTag: tag) },
        resolveUniversal: WhisperPreviewDeliveryWiring.makeMeetingResolver(
          modelDelivery: modelDelivery, settings: settings),
        isHeartStreaming: { [settings, liveRecordingState] in
          await MainActor.run {
            WhisperPreviewDeliveryWiring.meetingDecodeMustWait(
              settings: settings, dictationActive: liveRecordingState.isDictationActive)
          }
        }),
      choiceOwner: meetingLiveWordsChoice)
    // #3973: removing the Universal model lets dictation's preview and the meeting's live
    // words both go before the one residency wait and the delete.
    PreviewModelRemoval.install(
      on: modelDelivery, dictation: livePreview, meeting: meetingLiveWords)
    var meetingInputs = MeetingWiring.Inputs(
        store: MeetingStore(),
        settings: settings, permissions: permissions, otherAudioHold: otherAudioHold,
        transcriptCoordinator: transcriptCoordinator,
        isDictationIdle: { [liveRecordingState, engineCoordinator] in
          // Paste runs inside `.polishing`, so `isDictationActive` covers it; the clipboard
          // restore after it is a pasteboard write, not compute, and is not waited for.
          !liveRecordingState.isDictationActive && !engineCoordinator.isMintingAnySession
        },
        dictationWakes: meetingWakes,
        sharedEngine: MeetingWiring.SharedEngine(
          admission: .live(lease: engineLease, as: .meeting),
          isSwitchSettled: { [weak engineCoordinator] in
            // A switch refused because the picked model is not downloaded never applies; the
            // pass then uses the running engine instead of waiting for it (#4052 review).
            guard let status = engineCoordinator?.status else { return true }
            return status.selected == status.active || !status.selectedInstalled
          },
          activeBackend: { [asrManager] in asrManager.activeBackendType },
          ensureReady: { [weak engineCoordinator, activeEngine] in
            await MeetingWiring.borrowedEngineReadiness(
              switchRefused: {
                guard let status = engineCoordinator?.status else { return false }
                return status.selected != status.active && !status.selectedInstalled
              },
              ensureSelected: {
                switch await ensureSelectedEngineReady() {
                case .ready: .ready
                case .notInstalled: .notInstalled
                case .notReady: .notReady
                }
              },
              readyRunning: {
                guard (try? await activeEngine.load()) != nil else { return false }
                return await activeEngine.isLoaded()
              })
          },
          isModelLoaded: { [asrManager] in asrManager.isModelLoaded },
          isLoadOrUnloadInFlight: { [concreteASRManager] in concreteASRManager.isLoadOrUnloadInFlight },
          publishedSelection: { [concreteASRManager] in concreteASRManager.publishedSelection },
          transcribe: { [activeEngine] samples, language in
            // #4105: the meeting's transcript language, never dictation's setting.
            var options = TranscriptionOptions.default
            options.language = language
            return try await activeEngine.transcribe(samples, options, nil)
          },
          disarmEngineTimers: disarmEngineTimers,
          rearmEngineTimers: rearmEngineTimers,
          recoveryRecheck: {
            recoveryCoordinatorForEngineMutationScope?.requestRecoveryRecheck()
          }),
        memoryPressure: meetingMemoryPressure,
        offlineModeAdmission: concreteASRManager,
        meetingSelection: { [parakeetUpgrade] in await parakeetUpgrade.meetingSelection() },
        modelUseGate: modelDelivery.controller.meetingModelUseGate,
        isDeliveryEnabled: { [modelDelivery] in modelDelivery.parakeetHandle?.isEnabled() ?? false },
        workChanged: { [weak engineCoordinator] in engineCoordinator?.poke(.parakeetUpgradeOwed) },
        log: { line in
          Task { await AppLogger.shared.log(line, level: .info, category: "Meetings") }
        },
        keychain: keychainManager,
        detectedStartWanted: { [meetingBox] in
          meetingBox.callDetection?.detectedStartStillWanted() ?? false
        })
    meetingInputs.liveWords = meetingLiveWords
    meetingInputs.liveVocabulary = { [weak livePreview] in
      livePreview?.vocabularySnapshot()
        ?? LivePreviewVocabulary(lookups: nil, contextualPhrases: [], dictionaryEnabled: false)
    }
    let meetingCoordinator = MeetingWiring.make(meetingInputs)
    meetingBox.coordinator = meetingCoordinator
    self.meetingCoordinator = meetingCoordinator
    let meetingStartFlow = MeetingStartFlow(
      dependencies: .init(
        isSetUp: { [settings] in settings.meetingOnboardingComplete },
        captureCallSound: { [settings] in settings.meetingCaptureCallSound },
        isExplained: { [settings] in settings.meetingCallSoundExplained },
        markExplained: { [settings] in settings.meetingCallSoundExplained = true },
        canStart: { [weak meetingCoordinator] in meetingCoordinator?.phase == .idle },
        start: { [weak meetingCoordinator] entryPoint, captureCallSound, callApp in
          guard let meetingCoordinator else { return .notIdle }
          return await meetingCoordinator.start(
            from: entryPoint, captureCallSound: captureCallSound, callApp: callApp)
        },
        microphoneNeedsAsking: { [permissions] in permissions.microphoneNeedsAsking },
        requestMicrophone: { [permissions] in await permissions.requestMicrophoneAccessOrOpenSettings() },
        // #4058: the call-sound explainer and setup are on the General tab.
        showMeetingPage: { [navigationCoordinator, appWindowCoordinator] in
          navigationCoordinator.request(.meetings(.general))
          appWindowCoordinator.showWindow()
        }))
    meetingBox.startFlow = meetingStartFlow
    self.meetingStartFlow = meetingStartFlow
    self.meetingOnboardingModel = MeetingOnboardingModel(
      dependencies: .init(
        // Live, not `permissions.microphoneStatus`: that copy refreshes on its own poll, so a
        // grant made in System Settings could still read as refused on return.
        microphoneStatus: { [permissions] in permissions.microphoneStatusLive },
        requestMicrophone: { [permissions] in await permissions.requestMicrophoneAccessOrOpenSettings() },
        callSoundStatus: { SystemAudioPermission.status() },
        requestCallSound: {
          SystemAudioPermission.isAvailable ? await SystemAudioPermission.request() : nil
        },
        calendarStatus: { CalendarAccess.status() },
        requestCalendar: { [permissions] in
          let status = await CalendarAccess.request()
          permissions.refreshCalendarStatus()
          return status
        },
        openCallSoundSettings: { [permissions] in permissions.openSystemAudioRecordingSettings() },
        openCalendarSettings: { [permissions] in permissions.openCalendarSettings() },
        settings: settings,
        emit: { TelemetryService.shared.trackMeetingSetup($0) }))
    let callDetection = CallDetectionCoordinator(
      dependencies: .init(
        settings: settings,
        meetingPhase: { [weak meetingCoordinator] in meetingCoordinator?.phase ?? .idle },
        stopMeeting: { [weak meetingCoordinator] in await meetingCoordinator?.stop() },
        requestStart: { [weak meetingStartFlow] family in
          await meetingStartFlow?.requestStart(from: .detected, callApp: family) ?? .notIdle
        },
        // The panel's Start a new recording is the user's own Start: the menu's route.
        startByUser: { [weak meetingStartFlow] family in
          await meetingStartFlow?.requestStart(from: .menu, callApp: family) ?? .notIdle
        },
        detectedStartIsBlocked: { [weak meetingStartFlow, weak meetingCoordinator] in
          (meetingStartFlow?.detectedStartIsBlocked() ?? true)
            || (meetingCoordinator?.startWouldBeRefused() ?? true)
        },
        dictationActive: { [liveRecordingState] in liveRecordingState.isDictationActive },
        // #4058: the prompt's Open settings and its turn-off-an-app tips point at Call Apps.
        showMeetingPage: { [navigationCoordinator, appWindowCoordinator] in
          navigationCoordinator.request(.meetings(.callApps))
          appWindowCoordinator.showWindow()
        },
        anchor: { [menuBarControllerHolder] in menuBarControllerHolder.controller?.statusItemFrame },
        emit: { TelemetryService.shared.trackMeetingCallPrompt($0) },
        evidence: { rule, pid in await CallEvidenceRead.bounded(rule: rule, pid: pid) },
        makePresenter: { [overlayEffects] anchor in
          CallPromptPanel(anchor: anchor, makePanel: overlayEffects.makePanel)
        }))
    meetingBox.callDetection = callDetection
    self.callDetection = callDetection
    self.meetingMemoryPressure = meetingMemoryPressure
    self.transcriptCoordinator = transcriptCoordinator
    self.liveRecordingState = liveRecordingState
    self.lastRecordingResult = lastRecordingResult
    self.backendMetadata = backendMetadata
    self.engineCoordinator = engineCoordinator
    self.dictationRuntime = dictationRuntime
    self.hotkeyService = hotkeyService
    self.appWindowCoordinator = appWindowCoordinator
    self.previousApplicationTracker = previousApplicationTracker
    self.historyPaste = historyPaste
    self.menuBarController = menuBarController
    self.appLifecycleCoordinator = appLifecycleCoordinator

    // PR-C.1 of #763: the nine view-facing homes.
    self.settings = settings
    self.permissions = permissions
    self.asrManager = asrManager
    self.activeEngine = activeEngine
    self.customWordsCoordinator = customWordsCoordinator
    self.snippetsCoordinator = snippetsCoordinator
    self.contactsImportCoordinator = contactsImportCoordinator
    self.bulkImportEnrichmentCoordinator = bulkImportEnrichmentCoordinator
    self.setup = setup
    self.whisperMigration = whisperMigration
    self.localPolishRuntimes = localPolishRuntimes
    self.modelDelivery = modelDelivery
    self.checkerEligibility = checkerEligibility
    self.audioDeviceList = audioDeviceList
    self.pillAppearance = pillAppearance
    self.inputDevicePreferenceReconciler = inputDevicePreferenceReconciler
    self.aiAvailability = aiAvailability
    self.keychainManager = keychainManager
    self.llmDiscovery = llmDiscovery
    let polishSetupMonitor = PolishSetupMonitor(
      readInputs: {
        [settings, localPolishRuntimes, aiAvailability, setup, llmDiscovery, savedKeyPresence] in
        PolishSetupInputs.live(
          settings: settings, localPolishRuntimes: localPolishRuntimes,
          aiAvailability: aiAvailability, setup: setup, llmDiscovery: llmDiscovery,
          savedKeyPresence: savedKeyPresence)
      },
      ollamaRefresh: OllamaOffPageRefresh(
        requestOnce: { [weak setup] in setup?.requestOffPageOllamaRefresh() },
        cancel: { [weak setup] in setup?.cancelOffPageOllamaRefresh() }),
      appleRefresh: { [weak aiAvailability] in aiAvailability?.appleIntelligencePolishSucceeded() },
      // A take that found no key in the Keychain is that read's answer; no second read.
      recordKeyEvidence: { [savedKeyPresence] provider, state, readAt in
        savedKeyPresence.recordRead(state, for: provider, readAt: readAt)
      },
      // #3988: the notice history lives in THIS build's own defaults domain, never the unified
      // settings suite, so the dev build and the shipped app never share a day or a quiet.
      noticeStore: OutsideStopNoticeStore(defaults: .standard))
    polishSetupMonitorHolder.monitor = polishSetupMonitor
    menuBarControllerHolder.controller = menuBarController
    savedKeyPresence.onChange = { [weak polishSetupMonitor] in
      polishSetupMonitor?.configurationOrEligibilityChanged()
    }
    // #3438 chunk 6: the card after a dictation, offered for a take the monitor took in, and
    // withdrawn in the same turn its episode stops applying.
    let polishSetupCard = PolishSetupCardPresenter(
      overlay: recordingOverlay, monitor: polishSetupMonitor,
      openAIPolish: { [weak navigationCoordinator, weak appWindowCoordinator] in
        navigationCoordinator?.request(.aiPolish)
        appWindowCoordinator?.showWindow()
      })
    polishSetupMonitor.onEpisodeChange = { [weak polishSetupCard] in polishSetupCard?.reconcile() }
    // #3438 chunk 4: both dictation drivers freeze each take's AI polish setup, ask the monitor
    // to confirm a setup problem, write it on the take's terminal row, and hand the concluded
    // take's outcome back. One value for both, so the two backends cannot be wired apart.
    let polishSetupTakeHooks = PolishSetupTakeHooks(
      // A recording starting is where a pending or shown card stops applying.
      freeze: { [weak polishSetupMonitor, weak polishSetupCard] in
        polishSetupCard?.stop()
        return polishSetupMonitor?.freezeTakeContext()
      },
      classify: { [weak polishSetupMonitor] evidence, take in
        polishSetupMonitor?.confirmedSetupProblem(evidence, for: take)
      },
      recordTerminalProblem: { takeID, tag in
        TelemetryService.shared.recordPolishSetupProblem(takeID: takeID, tag: tag)
      },
      // One ingestion authority: the card is offered only for a take the monitor took in.
      ingest: { [weak polishSetupMonitor, weak polishSetupCard] outcome, mayOfferCard in
        guard polishSetupMonitor?.ingest(outcome) == true else { return }
        polishSetupCard?.offer(
          after: outcome, dataLossDisclosureScheduled: mayOfferCard == false)
      })
    kernelDriver.polishSetupHooks = polishSetupTakeHooks
    whisperKernelDriver.polishSetupHooks = polishSetupTakeHooks
    self.polishSetup = PolishSetupWiring(
      savedKeyPresence: savedKeyPresence, monitor: polishSetupMonitor, card: polishSetupCard)
    self.vocabularyPackManager = vocabularyPackManager
    // #2381. Built from three collaborators this root already holds; it adds no new dependency of
    // its own and reaches nothing the root did not already have.
    self.quickAdd = quickAdd

    // #832/#913 PR8: App-owned output-safety classifier holder.
    self.outputClassifierHolder = outputClassifierHolder

    // #1173: App-owned settings-change telemetry observer.
    self.settingsChangeTelemetry = settingsChangeTelemetry

    // #1171 — launch the coordinator's reconcile worker + Whisper setup-state
    // observation and fire the initial reconcile. Wiring above (the picker /
    // recovery / driver-state pokes) is all set, so the worker drains correctly.
    // At boot active == selected (`setInitialBackendType` above), so the first
    // reconcile is a converged no-op.
    // 2c: the Remove refusal reads BOTH session authorities from their owners
    // (Codex 2c-r5 P2): the frozen-config read (PipelineSettingsSync, which
    // owns both drivers) AND the minting gate (EngineCoordinator, gate 5's
    // owner) — a start that has committed but not yet frozen its config would
    // otherwise read as "no session" and let Remove delete under it. nil
    // either way refuses, fail safe.
    // #2648: the lease term is the THIRD clause and the general one.
    //
    // **Enumerated rather than patched, because this is the third seam an import
    // needed.** Every place the composition root answers "may I mutate, unload
    // or delete the shared engine or a polish runtime right now" is:
    //
    // | seam | who answers | import covered by |
    // |---|---|---|
    // | `EngineCoordinator` gate 5 / 6 / 6b | recording, recovery, import | `isFileImportRunning` → `isEngineHeld` |
    // | `egOneRuntime.isPinnedInFlight` (+ S1-mini) | `pinnedLocalProvider()` | `importPinnedLocalProvider` |
    // | `isBlockedByOtherPinnedSession` (+ S1-mini) | `pinnedLocalProvider()` | same |
    // | `isSharedEngineBusy` (+ S1-mini) | `EngineLease.isBusy` | the lease itself |
    // | `isOllamaModelPinnedInFlight` | the two session configs | `importPinnedOllamaModel` |
    // | the ASR idle-unload timer | `cancelIdleTimer` / `noteTranscriptionComplete` | bracketed around the hold |
    // | THIS one, Whisper Remove | dictation config + minting flag | the lease term below |
    //
    // Sweeping that list found exactly one gap, this seam: an All Languages
    // import held the engine while Remove deleted the model out from under it,
    // because the closure asked only about DICTATION. `isBusy` is the universal
    // answer — every workload that can occupy the one inference slot takes the
    // claim — and it stays true after Stop until the cancelled work has
    // physically exited, which is the window the refusal most needs to cover.
    // Found by Codex; the sweep is mine.
    setup.whisperSetup.isDictationInFlight = {
      [weak settingsSync, weak engineCoordinator, weak engineLease] in
      (settingsSync?.isWhisperDictationInFlight() ?? true)
        || (engineCoordinator?.isMintingWhisperSession ?? true)
        || (engineLease?.isBusy ?? true)
    }
    engineCoordinator.start()

    // Initialize observability (PostHog + Sentry) unconditionally at launch.
    // #919: same timing as before — the shell's `App.init()` constructs this
    // bootstrapper synchronously, before any NSApplicationDelegate callback.
    // #3269: the stored switches decide whether PostHog starts and Sentry's mode for this run.
    ObservabilityBootstrap.initialize(
      usageMetrics: settings.shareUsageMetrics, crashReports: settings.sendCrashReports)
    // #3849: the previous quit's model-release timeout note, if any: removed, and reported only
    // when crash reports are on (this build's namespace only).
    ModelReleaseTimeoutNote.consumeAtLaunch(crashReportsEnabled: settings.sendCrashReports)
    // #3269: the local diagnostics diary records whatever the switches say; it never uploads.
    TelemetryService.shared.activateDiagnosticsDiary()
    // #3269: saved bug reports are delivered on their own, independent of both switches.
    Task { await FeedbackReporter.startDelivery() }
    // #3275: Send Feedback checks the help center first. Whether it runs for anyone is the
    // server's kill switch; the app always asks and sends the report unchanged when told to.
    HelpCheckWiring.install(on: FeedbackSubmission.shared, settings: settings)

    // #832/#913 PR8: prewarm the output-safety classifier off the heart path.
    // #3853: only while a consumer needs it (dictation's or Transcribe a File's provider is
    // Apple Intelligence); later provider changes load or release it through the same owner.
    // Never blocks launch, recording, ASR, or paste.
    settingsSync.reconcileOutputClassifierDemand(settings: settings, reason: "launch")
  }

  /// Load the on-device output-safety classifier in the background and publish
  /// it into `holder`. Idempotent (no-op if already loaded); whether it is needed is
  /// `PipelineSettingsSync.reconcileOutputClassifierDemand`'s call (#3853). Every failure
  /// fails open (the polish path keeps
  /// #996: Debug builds mirror the learn events into app.log for Live UAT;
  /// Release emits to the vendors only.
  private static func learnFromEditsTelemetrySink() -> any LearnFromEditsRuntimeTelemetrySink {
    #if DEBUG
      return LearnFromEditsLoggingSink(TelemetryService.shared)
    #else
      return TelemetryService.shared
    #endif
  }

  /// working without the extra safety net). Static so the settings sync's load
  /// closure can call it without capturing a not-yet-initialized `self`.
  /// #832/#913 PR8.
  private static func prewarmOutputClassifier(holder: OutputClassifierHolder) {
    // #3853: stamped now, not when the task runs, so a release in between refuses this load.
    let requestedAt = holder.releaseGeneration
    Task {
      let start = DispatchTime.now()
      let outcome = await holder.beginLoadIfNeeded(requestedAt: requestedAt) {
        guard let resourceURL = Bundle.main.resourceURL else {
          throw OutputClassifierError.disabled(.missingFile)
        }
        return try await CoreMLOutputClassifier.load(resourceURL: resourceURL)
      }
      let elapsedMs = Int(
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
      let plan = OutputClassifierEmissionPolicy.forOutcome(outcome)
      if let logMessage = plan.logMessage {
        await AppLogger.shared.log(logMessage, level: .info, category: "LLM")
      }
      if let category = plan.postHogErrorCategory {
        // #1177 (Telemetry Bible Phase 8): the polish path silently lost its safety
        // net. Population event for the aggregate fail-open rate, tagged by which
        // of the three observation units this is (#1452 — see
        // `OutputClassifierEmissionPolicy`). @MainActor static → direct emit.
        TelemetryService.shared.limbFailureObserved(
          limb: "output_safety", operation: "classifier_prewarm", result: "fell_open",
          errorCategory: category, durationMs: plan.attemptedRealLoad ? elapsedMs : nil)
      }
      if let sentryReason = plan.sentryReason {
        // #1452: at most one alert per process per disablement — repeated
        // provider-switch triggers after this point return
        // `.skippedPermanentlyDisabled` and never reach this branch again.
        SentryBreadcrumb.captureError(
          OutputClassifierError.disabled(sentryReason), category: .outputClassifierLoadFailed,
          stage: "llm", fingerprintDetail: sentryReason.rawValue)
      }
    }
  }

  // MARK: - Lifecycle (forwarded by the shell `AppDelegate`)
  // #919: preserves the exact pre-split timing — `startUpdater()` runs in
  // `applicationWillFinishLaunching`, before the first SwiftUI scene body
  // evaluates (issue #739 / SparkleUpdateController contract).

  package func applicationWillFinishLaunching() {
    // #2480: regular before any scene or Sparkle window exists, so the launch window
    // opens with the app menu, Dock icon and Cmd-Tab entry.
    appWindowCoordinator.beginLaunch()
    sparkleUpdateController.startUpdater()
    // #1019, #3194: the install affordances (menu item / notification) refuse while a relaunch
    // would lose work, by the same owner as the language relaunch: dictation, a file
    // transcription or speaker retry, a recovery replay or a recording starting.
    sparkleUpdateController.updateCoordinator?.workInFlightProvider = { [weak self] in
      guard let self else { return false }
      return AppRelauncher.workInFlight(
        dictationActive: liveRecordingState.isDictationActive, fileImport: fileImportCoordinator)
        || AppRelauncher.backgroundWorkInFlight()
    }
    // #2197: same refusal while clipboard cleanup is pending (why: its own doc).
    sparkleUpdateController.updateCoordinator?
      .clipboardCleanupPendingProvider = { ClipboardCleanup.hasPending }
    // #3142 5B: the language relaunch also refuses mid recovery replay or recording start (why:
    // its own doc).
    AppRelauncher.backgroundWorkInFlight = AppRelauncher.backgroundWork(
      isRecovering: { [weak self] in self?.recoveryCoordinator.isRecovering ?? false },
      isMinting: { [weak self] in self?.engineCoordinator.isMintingAnySession ?? false },
      meetings: meetingCoordinator)
    AppLanguagePreference.live.forgetUnshippedOverride()
    // #1029: install the notification tap delegate eagerly at launch (decoupled
    // from posting) so a tap on an already-delivered "update ready" notification —
    // or a cold launch from it — always routes, even when the once-per-version
    // guard suppresses a fresh post on rehydrate.
    sparkleUpdateController.updateCoordinator?.activateNotificationTapRouting()
    // #958: proactive launch check, right after startUpdater per Sparkle guidance.
    sparkleUpdateController.updateCoordinator?.checkForUpdatesProactively(trigger: "launch")
    // #1019: begin observing wake / network for an always-on, windowless user.
    updateTriggerCoordinator.start()
  }

  package func applicationDidFinishLaunching() {
    // #1413: FIRST, synchronously, before `runDidFinishLaunching` starts the
    // dictation hotkey (`AppLifecycleCoordinator.swift` → `startHotkeyServiceIfEnabled`):
    // a Mac left lowered by a dead process is put back before any take can start.
    dictationRuntime.otherAudioHold.adoptOrphans()
    // #3972 R3/R15: meetings recover after the orphaned hold is restored, before any take.
    meetingMemoryPressure.start()
    meetingCoordinator.launch()
    callDetection.start()
    appLifecycleCoordinator.runDidFinishLaunching()
    // #2480: bring the launch window to the front.
    appWindowCoordinator.finishLaunch()
    // #2381.
    quickAdd.install()
    // #3438: the setup warnings watch dictation's chosen model from launch, Settings open or not.
    polishSetup.monitor.start()
    // #1063 PR2: recover orphan crash-recovery spools behind the blocking
    // "recovering" pill. Strict limb, single-flight, one attempt per orphan.
    Task { await recoveryCoordinator.scanAndRecover() }
    // #2186: deletion must not depend on a view mounting. Its OWN task, NO
    // ordering against the scan — the sweep refuses to delete a row whose spool
    // survives, so it is safe whenever it runs. Chaining it was tried and cloud
    // review refuted both halves. Bound by `EscapeRecoveryDiskExpiryTests`.
    Task { await transcriptCoordinator.sweepExpiredPending() }
    // #2377 Phase 6 C4: registers a one-shot idle observer and returns
    // immediately — root construction happens later, at the main run loop's
    // next `.beforeWaiting`, not here. No outer `DispatchQueue.main.async`:
    // that would add a second hop without establishing idleness, which is
    // the whole reason this call exists instead of the demand-driven path's
    // existing `DispatchQueue.main.async` default.
    recordingOverlay.prewarmFirstRender()
    #if DEBUG
      // #2885: after launch, like `quickAdd.install()` above, and after the coordinator
      // exists, which the initializer guarantees.
      debugImportDoor.install()
      // #3765: same moment. A door that cannot listen logs why and leaves the app as it is.
      devControlInstall = Task { [devControlDoor] in
        let result = await devControlDoor.install()
        guard result != .ready else { return }
        await AppLogger.shared.log(
          "[DevControl] not installed: \(result)", level: .info, category: "Debug")
      }
    #endif
  }

  /// #2480: a Dock-icon click (or a double-click on the running app). Returns what
  /// AppKit's `applicationShouldHandleReopen` expects: `false` when handled.
  /// AppKit's own `hasVisibleWindows` is deliberately not consulted: it counts the
  /// recording pill and the Quick Add panel, so it can be true with Settings closed.
  package func applicationShouldHandleReopen() -> Bool {
    !appWindowCoordinator.reopenFromDock()
  }

  package func applicationDidBecomeActive() {
    appLifecycleCoordinator.runDidBecomeActive()
    // #3438: after the pane-scoped probe above, so a visible watch is never doubled.
    polishSetup.monitor.applicationDidBecomeActive()
    // #958: proactive foreground check (post-sleep freshness), strict >=3600 gated.
    sparkleUpdateController.updateCoordinator?.checkForUpdatesProactively(trigger: "foreground")
  }

  package func applicationWillTerminate() {
    #if DEBUG
      // #2885: stop answering, and stop watching, before anything below tears down.
      debugImportDoor.uninstall()
      // #3765: close admission before any owner the door reads is torn down. Uninstall
      // also covers an install that has not started yet: it then refuses.
      devControlInstall?.cancel()
      devControlDoor.uninstall()
    #endif
    // #1413: finish a live hold from memory before anything below tears down —
    // a Cocoa quit concludes no take, so this is the only path that restores
    // the volume for a quit mid-dictation.
    dictationRuntime.otherAudioHold.finishForTermination()
    // #3972 R18: close meeting admission, cancel its pass, stop capture and close both files
    // against one shared one-second deadline.
    callDetection.shutDown()
    meetingCoordinator.prepareForTermination(deadline: .now() + 1)
    meetingMemoryPressure.stop()
    // #3438: stop observing before the owners it reads are torn down.
    polishSetup.card.stop()
    polishSetup.monitor.stop()
    // #3269: best effort; the process may exit first, and every outbox write is atomic anyway.
    Task { await FeedbackReporter.stopDelivery() }
    // #1271: kill the EG-1 child SYNCHRONOUSLY — `Process` children survive
    // parent exit (Codex r1 proved empirically); crash orphans are reaped by
    // the stale-sweep in EGOneServerManager.start on next launch.
    localPolishRuntimes.egOne.terminateServerForAppQuit()
    // #3853: children first, then native runtimes. Drop the word check's MLX model without
    // waiting (its cleanup runs off this thread), before the lifecycle flush and the
    // transcribe.cpp release below.
    checkerEligibility.wordCheck?.releaseForTermination()
    // #1019: tear down the network path monitor + wake observer.
    updateTriggerCoordinator.stop()
    // #1176: a Cocoa quit during onboarding is an abandon (best-effort — kill -9
    // bypasses this). Capture BEFORE the Phase-1 flush in runWillTerminate so it is
    // durable. Deduped by the box's terminal guard (a clean finish or a prior
    // window-close abandon suppresses it).
    onboardingProgress.emitAbandonIfInFlight(
      reason: "app_quit", micStatus: permissions.microphoneStatusString,
      // Live read so a just-before-quit grant isn't logged denied (cloud Codex r3).
      accessibilityStatus: permissions.accessibilityGrantedLive ? "granted" : "denied")
    appLifecycleCoordinator.runWillTerminate()
    // #3849: LAST, synchronously, after every step above: free every transcribe.cpp model
    // (Whisper, Universal Live Preview) so the Metal device destructor at exit finds none
    // alive. Returns when all are freed; a native call stuck past the 2 s bound ends the
    // process here instead, after a note the next launch reports.
    TranscribeCppProcessExit.releaseBeforeExit()
  }

  // MARK: - Window titles (so the shell needs no EnviousWisprCore dependency)

  package var mainWindowTitle: String { LaunchWindowIdentity.mainTitle }
  package var onboardingWindowTitle: String { LaunchWindowIdentity.onboardingTitle }
  package var onboardingWindowID: String { LaunchWindowIdentity.onboardingID }

  // MARK: - Root content
  // Homes are injected here, INSIDE the kit — the shell injects nothing, so no
  // home type crosses the module boundary (keeps the public surface tiny).

  package func mainWindowContent() -> some View {
    MainWindowRoot(b: self)
  }

  package func onboardingWindowContent() -> some View {
    OnboardingWindowRoot(b: self)
  }
}

// MARK: - Engine switch sequence (#3849)

extension WisprBootstrapper {
  /// #3849: the switch `EngineCoordinator` performs at step 7 (`performSwitch`). Away from
  /// Whisper, Whisper parks and its model is physically freed before the manager switches, so
  /// the replacement engine's warm (coordinator step 8) never runs beside it. Toward Whisper,
  /// Whisper stays parked while the manager unloads the outgoing engine, and is unparked only
  /// once it is the active engine, before this returns. No time limit: the switch waits for
  /// physical cleanup (quit has its own bound).
  static func switchEngine(
    to backend: ASRBackendType,
    activeBackend: () -> ASRBackendType,
    parkWhisper: () async -> UnloadReceipt?,
    switchManager: (ASRBackendType) async -> Void,
    unparkWhisper: () async -> Void,
    log: (String) async -> Void
  ) async {
    if activeBackend() == .whisper, backend != .whisper {
      if let receipt = await parkWhisper() {
        await log(
          "Whisper model released for engine switch freed=\(receipt.freed) "
            + "remaining=\(receipt.remaining)")
      } else {
        await log("Whisper model release for engine switch: no Whisper engine to park")
      }
    }
    await switchManager(backend)
    if backend == .whisper, activeBackend() == .whisper {
      await unparkWhisper()
    }
  }
}

/// The main window's root view. Owns the onboarding-presented view-state (was
/// `@State` on the old App struct) and injects every App-owned home.
private struct MainWindowRoot: View {
  let b: WisprBootstrapper
  @State private var isOnboardingPresented: Bool

  init(b: WisprBootstrapper) {
    self.b = b
    // #923: derive from the SettingsManager instance, not a raw `.standard` read
    // (which on the dev build would hit the wrong per-build store).
    _isOnboardingPresented = State(initialValue: !b.settings.hasCompletedOnboarding)
  }

  var body: some View {
    UnifiedWindowView()
      // 750 = two-card frame chrome (outer inset 28 + sidebar 200 + spacing 14 =
      // 242) + the History split floors inside the detail card (230+8+260=498),
      // so the window can never crush the History split (#1024; #1296 frame).
      .frame(minWidth: 750, minHeight: 400)
      .environment(b.navigationCoordinator)
      .environment(b.diagnosticsCoordinator)
      #if DEBUG
        .environment(b.pillPreviewController)
      #endif
      .environment(b.languageSuggestionPresenter)
      .environment(b.updateCoordinatorHolder)
      .environment(\.settingsKeyMonitor, b.settingsKeyMonitor)
      .environment(b.transcriptCoordinator)
      .environment(b.fileImportCoordinator)
      .environment(b.meetingCoordinator)
      .environment(b.meetingStartFlow)
      .environment(b.meetingOnboardingModel)
      .environment(b.liveRecordingState)
      .environment(b.lastRecordingResult)
      .environment(b.backendMetadata)
      .environment(b.engineCoordinator)
      .environment(b.modelDelivery)
      .environment(b.checkerEligibility)
      .environment(b.dictationRuntime)
      .environment(b.appWindowCoordinator)
      .environment(b.previousApplicationTracker)
      .environment(b.historyPaste)
      // The nine view-facing homes (epic #763).
      .environment(b.settings)
      .environment(b.pillAppearance)
      .environment(b.permissions)
      .environment(b.customWordsCoordinator)
      .environment(b.snippetsCoordinator)
      .environment(b.contactsImportCoordinator)
      .environment(b.setup)
      .environment(b.localPolishRuntimes.egOne)
      // #2649: both engines are `EGOneRuntime`, and `@Environment` keys by TYPE,
      // so injecting the second directly would silently replace the first. The
      // set names them instead.
      .environment(b.localPolishRuntimes)
      .environment(b.audioDeviceList)
      // Only the microphone status view invokes this reader and observes capture changes.
      // No second state owner or capture command; the diagnostic UID survives stop.
      .environment(
        \.microphoneCapturePresentation,
        {
          MicrophoneCapturePresentation(
            isCapturing: b.liveRecordingState.audioCapture.isCapturing,
            boundDeviceUID:
              b.liveRecordingState.audioCapture.zeroSignalDiscriminatorDevice?.deviceUID)
        }
      )
      .environment(b.aiAvailability)
      .environment(b.llmDiscovery)
      .environment(b.polishSetup.savedKeyPresence)
      .environment(b.polishSetup.monitor)
      .environment(b.vocabularyPackManager)
      // #996: the Learning row's enabled state (auto-learn, 2026-09-21 plan).
      .environment(b.learnFromEdits.availability)
      .environment(\.asrManager, b.asrManager)
      .environment(\.activeEngine, b.activeEngine)
      .environment(\.keychainManager, b.keychainManager)
      .background(
        ActionWirer(
          settings: b.settings,
          appWindowCoordinator: b.appWindowCoordinator,
          menuBarController: b.menuBarController,
          onboardingProgress: b.onboardingProgress,
          isOnboardingPresented: $isOnboardingPresented
        )
      )
  }
}

/// The onboarding window's root view.
private struct OnboardingWindowRoot: View {
  let b: WisprBootstrapper

  var body: some View {
    OnboardingV2View(
      onComplete: { b.appWindowCoordinator.closeOnboardingWindow() },
      onboardingProgress: b.onboardingProgress
    )
    .environment(b.navigationCoordinator)
    .environment(b.languageSuggestionPresenter)
    .environment(b.dictationRuntime)
    // #3546: the warming screen's retry reaches the Parakeet upgrade policy.
    .environment(b.modelDelivery)
    // #2196 — the practice screen reads BOTH of these, and a type-based
    // `@Environment` with no default TRAPS AT RUNTIME rather than failing to
    // compile. Cloud review caught this as a P1: `liveRecordingState` was added
    // here when the screen started reading it, and `transcriptCoordinator` was
    // added to the SCREEN a round later without coming back to this list. The
    // Live UAT that would have caught it ran before that round.
    .environment(b.transcriptCoordinator)
    // The practice screen needs to know a take is in flight.
    // `LiveRecordingState.isDictationActive` is true while EITHER pipeline is
    // recording, transcribing or polishing, and it is already @Observable, so
    // the screen reads an existing signal rather than growing a new one. The
    // main window has had this injected all along; onboarding never needed it
    // until it hosted a dictation target.
    .environment(b.liveRecordingState)
    .environment(b.appWindowCoordinator)
    // The nine view-facing homes (epic #763).
    .environment(b.settings)
    .environment(b.permissions)
    .environment(b.customWordsCoordinator)
    .environment(b.setup)
    .environment(b.audioDeviceList)
    .environment(b.aiAvailability)
    .environment(b.llmDiscovery)
    .environment(b.polishSetup.savedKeyPresence)
    .environment(b.polishSetup.monitor)
    .environment(\.asrManager, b.asrManager)
    .environment(\.activeEngine, b.activeEngine)
    .environment(\.keychainManager, b.keychainManager)
  }
}

/// Hidden view that wires SwiftUI environment actions into App-owned homes.
/// Must live inside a SwiftUI view hierarchy to access @Environment.
private struct ActionWirer: View {
  /// The onboarding-auto-open gate reads `onboardingState` off the settings
  /// store directly (epic #763).
  let settings: SettingsManager
  /// PR-B.2 of #763: the three SwiftUI window bridges are wired onto the
  /// coordinator now, not AppDelegate.
  let appWindowCoordinator: AppWindowCoordinator
  /// PR-B.3 of #763: onboarding-dismissal icon refresh targets the menu home.
  let menuBarController: MenuBarController
  /// #1176: begin a fresh onboarding session on every window open (first-run AND
  /// Diagnostics restart both funnel through `openOnboardingAction`).
  let onboardingProgress: OnboardingProgress
  @Binding var isOnboardingPresented: Bool
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .task {
        appWindowCoordinator.openMainWindowAction = { [openWindow] in
          openWindow(id: "main")
        }
        appWindowCoordinator.openOnboardingAction = { [openWindow, onboardingProgress, settings] in
          // #1176: every onboarding presentation funnels through here. `begin` starts
          // a fresh session only when none is in flight, so a refocus of the open
          // window (status-menu "Continue Setup…") never rewinds it — see the guard
          // in `OnboardingProgress.begin`. `source` reads the durable everCompleted
          // flag from the shared settings store.
          let source = settings.onboardingEverCompleted ? "diagnostics_restart" : "first_run"
          onboardingProgress.begin(source: source)
          openWindow(id: AppConstants.onboardingWindowID)
        }
        appWindowCoordinator.dismissOnboardingAction = { [dismissWindow] in
          dismissWindow(id: AppConstants.onboardingWindowID)
        }
        // PR-B.2 of #763: drain any queued onboarding-open request FIRST.
        let replayed = appWindowCoordinator.consumePendingOpenOnboarding()
        // Auto-open onboarding if needed (first launch), only if nothing was
        // already replayed.
        if !replayed, settings.onboardingState != .completed {
          appWindowCoordinator.openOnboardingWindow()
        }
      }
      .onChange(of: isOnboardingPresented) { _, newValue in
        if !newValue {
          // State-driven dismissal: binding flipped to false → close window.
          dismissWindow(id: AppConstants.onboardingWindowID)
          appWindowCoordinator.refreshAfterOnboardingDismissal()
          menuBarController.updateIcon()
        }
      }
  }
}

/// Pure mapping from a classifier-load outcome to what `WisprBootstrapper`
/// should log, count, and alert. Colocated with the sole caller
/// (`prewarmOutputClassifier`); stateless and dependency-free (no
/// `TelemetryService`/`SentryBreadcrumb` import) so the outcome→emission
/// decision — the actual alert-dedup contract — is independently unit-testable
/// without touching Sentry or PostHog. #1452.
struct OutputClassifierEmissionPolicy: Equatable {
  let logMessage: String?
  let postHogErrorCategory: String?
  let sentryReason: OutputClassifierDisabledReason?
  /// True only when this call actually attempted a load (so `elapsedMs` is a
  /// real, meaningful duration) — false for suppressed repeats, which measure
  /// nothing because no load was attempted. Kept as an explicit field rather
  /// than inferring it from `sentryReason == nil`, which is also nil for
  /// `.failedRetryable` (a real attempt that just isn't alert-worthy).
  let attemptedRealLoad: Bool

  static func forOutcome(_ outcome: OutputClassifierAttemptOutcome) -> Self {
    switch outcome {
    case .skippedAlreadyReady, .skippedLoadInProgress, .discardedAfterRelease:
      // #3853: a load abandoned by `release()` is the demand going away, not a failure.
      return .init(
        logMessage: nil, postHogErrorCategory: nil, sentryReason: nil, attemptedRealLoad: false)
    case .succeeded:
      return .init(
        logMessage: "[OutputClassifier] preWarm complete", postHogErrorCategory: nil,
        sentryReason: nil, attemptedRealLoad: true)
    case .skippedPermanentlyDisabled(let reason):
      // Suppressed repeat: counted (unit = "provider-triggered observation of an
      // already-disabled classifier"), never re-alerted — this IS the fix.
      return .init(
        logMessage: nil, postHogErrorCategory: "suppressed_repeat:\(reason.rawValue)",
        sentryReason: nil, attemptedRealLoad: false)
    case .failedFirstTime(let reason):
      return .init(
        logMessage: "[OutputClassifier] preWarm failed reason=\(reason.rawValue) — fail open",
        postHogErrorCategory: "attempted_load:\(reason.rawValue)", sentryReason: reason,
        attemptedRealLoad: true)
    case .failedRetryable(let category):
      // Not the classifier's fault (cancellation / unknown transient error) — counted,
      // never alerted, and the holder itself already allows a later retry.
      return .init(
        logMessage: nil, postHogErrorCategory: "retryable:\(category)", sentryReason: nil,
        attemptedRealLoad: true)
    }
  }
}

/// Lets owners built before EnviousMeet's coordinator read it (#3972 C4a). Set once.
@MainActor
final class MeetingCoordinatorBox {
  weak var coordinator: MeetingCoordinator?
  weak var startFlow: MeetingStartFlow?
  /// #4012: call detection, for the DEBUG `call.simulate` command.
  weak var callDetection: CallDetectionCoordinator?

  /// #4069: whether "Turn off dictation during meetings" refuses a dictation start now: the
  /// switch is on and a meeting is starting, recording or stopping. No coordinator, no meeting.
  func refusesDictation(turnedOff: Bool) -> Bool {
    turnedOff && (coordinator?.isCapturing ?? false)
  }
}
