import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import SwiftUI

/// Root observable state for the entire application.
@MainActor
@Observable
final class AppState {
  // Settings
  var settings = SettingsManager()

  // Sub-systems
  let permissions = PermissionsService()
  let audioCapture: any AudioCaptureInterface
  let asrManager: any ASRManagerInterface
  let keychainManager = KeychainManager()
  let hotkeyService = HotkeyService()
  let recordingOverlay = RecordingOverlayPanel()
  // Phase F (#501) — setup-orchestration cluster moved out of AppState.
  // Holds ollamaSetup, whisperKitSetup, and the WhisperKit preload-observation
  // task. Constructed in init() after asrManager and whisperKitPipeline exist
  // (it needs both to drive the preload observer).
  let setup: SetupCoordinator
  let audioDeviceList = AudioDeviceList()
  let captureTelemetry = CaptureTelemetryState()

  // Pipelines — initialized after sub-systems
  let pipeline: TranscriptionPipeline
  let whisperKitPipeline: WhisperKitPipeline

  // PR9 of #763 — pipeline state-change side effects (overlay, hotkey
  // arbitration, telemetry, chip lifecycle, terminal settings sync) moved to
  // `DictationLifecycleCoordinator` under DictationRuntime. The factory +
  // lazy handlers + post-completion warning Task all sunset here. The icon
  // callback property also moved to the new home; AppDelegate sets it on the
  // coordinator now.

  /// Standalone service for re-polishing saved transcripts from the detail view.
  /// Completely decoupled from pipeline state machines.
  let polishService: TranscriptPolishService

  /// Forwards settings changes to pipelines and subsystems.
  let settingsSync: PipelineSettingsSync

  // PR9 of #763 — transcript-coordinator storage moved off AppState. The
  // composition root constructs it once and threads it into both the new
  // lifecycle home (caller of append) and `TranscriptWorkflowCoordinator`
  // (view-facing surface). AppState's init takes `TranscriptStore` so the
  // pipelines + polish service can still receive the shared store reference.

  /// True when recording is in hands-free (locked) mode via double-press.
  /// Read by the overlay to switch to the expanded lips visual.
  var isRecordingLocked: Bool = false

  /// PR4 of #763 (#252 fold-in): the chip presenter is set via setter
  /// injection by AppDelegate after both AppState and the presenter exist.
  /// Heart path: transient dispatch reference until PR9 (DictationLifecycleCoordinator)
  /// absorbs the pipeline state-change call sites + this reference, and PR10
  /// (DictationRuntime) absorbs the cancel call site. PR11 deletes AppState.
  /// Until attached, calls into it are silent no-ops (`?.`). DEBUG-only
  /// `ChipWiringDiagnostics.warnIfPresenterMissing` fires a one-shot warning
  /// if a chip event arrives before attachment (impossible in production).
  private(set) var languageSuggestionPresenter: LanguageSuggestionPresenter?

  /// Setter for `languageSuggestionPresenter`. Called once by AppDelegate
  /// after both AppState and the presenter exist (presenter needs
  /// `recordingOverlay` for its showOverlay closure; AppState constructs the
  /// overlay; so the wiring runs post-init in AppDelegate).
  func attachLanguageSuggestionPresenter(_ presenter: LanguageSuggestionPresenter) {
    self.languageSuggestionPresenter = presenter
  }

  /// PR7 of #763 — sunset PR9. App-owned home for live dictation facts
  /// (pipelineState, audioLevel, currentTranscript). Setter-injected `var`
  /// so the `AppStateCeilingsTests` collaborator parser (which counts only
  /// `let`) does not see it. Migration-period plumbing: AppState held the
  /// equivalent getters pre-PR7; PR9's `DictationLifecycleCoordinator`
  /// absorbs the push sites and this outlet evaporates.
  private(set) var liveRecordingState: LiveRecordingState?
  func attachLiveRecordingState(_ state: LiveRecordingState) {
    self.liveRecordingState = state
  }

  /// PR7 of #763 — sunset PR9. App-owned home for post-recording polish
  /// error state. AppState's existing state-change closures push
  /// `pipeline.lastPolishError` / `whisperKitPipeline.lastPolishError` into
  /// `lastRecordingResult?.polishError`; `toggleRecording` resets it on a
  /// new recording start. Setter-injected `var` — see ceiling note above.
  private(set) var lastRecordingResult: LastRecordingResult?
  func attachLastRecordingResult(_ result: LastRecordingResult) {
    self.lastRecordingResult = result
  }

  /// PR7 of #763 — sunset PR11. App-owned home for backend display labels
  /// (modelLabel, llmLabel, statusText). Setter-injected so AppDelegate's
  /// menu reads can resolve through this outlet during the migration;
  /// once AppDelegate shrinks per PR-B and AppState is deleted in PR11,
  /// this outlet evaporates with the host.
  private(set) var backendMetadata: BackendMetadata?
  func attachBackendMetadata(_ metadata: BackendMetadata) {
    self.backendMetadata = metadata
  }

  /// PR9 of #763 — weak ref to the new lifecycle home. AppState's PR10-scope
  /// start paths (`hotkeyService.onStartRecording`, `toggleRecording(source:)`)
  /// still need to call `cancelPendingWarning()` before a new recording
  /// overlay shows. PR10 retires this when start/stop/cancel migrate into
  /// `RecordingStarter` / `RecordingFinalizer`. Setter-injected `var` —
  /// uncounted by the ceiling parser (matches the pattern used for the four
  /// outlets above).
  private(set) weak var dictationLifecycleCoordinator: DictationLifecycleCoordinator?
  func attachDictationLifecycleCoordinator(_ coordinator: DictationLifecycleCoordinator) {
    self.dictationLifecycleCoordinator = coordinator
  }

  // Feature #8: custom word management — delegated to coordinator
  let customWordsCoordinator = CustomWordsCoordinator()

  /// Broadcasts custom-words changes to all registered consumers (pipelines'
  /// word-correction + polish steps, plus the re-polish service). Initialized
  /// at property declaration (no ctor dependencies); seeded with
  /// `customWordsCoordinator.customWords` in `init` before consumer
  /// registrations.
  let customWordsPropagator = CustomWordsPropagator()

  // Model discovery — delegated to coordinator
  let llmDiscovery: LLMModelDiscoveryCoordinator

  // Apple Intelligence availability — dedicated coordinator (replaces KeyValidationState proxy)
  let aiAvailability = AIAvailabilityCoordinator()

  // #585: heart-control dispatch recovery (lazy var so closures capture self; ignored by Observation).
  @ObservationIgnored
  private(set) lazy var heartControlRecovery: HeartControlRecovery = HeartControlRecovery(
    hideOverlay: { [recordingOverlay] in recordingOverlay.show(intent: .hidden) },
    setLocked: { [weak self] locked in self?.isRecordingLocked = locked },
    backend: { [weak self] in
      self?.asrManager.activeBackendType == .whisperKit ? "whisperkit" : "parakeet"
    })

  /// PR9 of #763 — `transcriptStore` is constructed by the composition root
  /// (`EnviousWisprApp.init`) and injected. This lets `TranscriptCoordinator`
  /// move off AppState (the composition root threads the same TC instance to
  /// the lifecycle coordinator + the transcript workflow coordinator). The
  /// pipelines + polish service still receive `transcriptStore` via this init.
  init(transcriptStore: TranscriptStore) {
    // XPC audio service — default ON (Step 7). Audio capture runs in a separate XPC
    // service process for crash isolation. Escape hatch: `defaults write ... useXPCAudioService -bool false`
    // Read directly from UserDefaults because `settings` is not yet available (stored
    // properties must all be initialized before `self` is accessible).
    // NOTE: .bool(forKey:) returns false for absent keys — use object() ?? true pattern
    // so existing installs (no key written) get the new default.
    let useXPC = UserDefaults.standard.object(forKey: "useXPCAudioService") as? Bool ?? true
    if useXPC {
      audioCapture = AudioCaptureProxy()
    } else {
      audioCapture = AudioCaptureManager()
    }

    // Phase 5: XPC ASR service — default ON (Stage F). ASR inference runs in a separate
    // XPC service process for memory isolation. Escape hatch: `defaults write ... useXPCASRService -bool false`
    // NOTE: .bool(forKey:) returns false for absent keys — use object() ?? true pattern.
    let useXPCASR = UserDefaults.standard.object(forKey: "useXPCASRService") as? Bool ?? true
    if useXPCASR {
      asrManager = ASRManagerProxy()
    } else {
      asrManager = ASRManager()
    }

    llmDiscovery = LLMModelDiscoveryCoordinator(keychainManager: keychainManager)

    // Phase 0 (#640) — single shared paste-completion registry. Constructed
    // first so both pipelines and the polish service receive the same
    // instance. NOT promoted to a top-level `let` collaborator (would breach
    // the AppState concrete-collaborator ceiling at 19); the polish service
    // exposes it as `polishService.pasteCompletionRegistry` for Phase 7
    // (#629) auto-learn subscription.
    polishService = TranscriptPolishService(
      keychainManager: keychainManager,
      transcriptStore: transcriptStore
    )

    // Both pipeline properties must be initialized before `self` can be used.
    // WhisperKitBackend default is large-v3-turbo; reconfigured from settings below.
    pipeline = TranscriptionPipeline(
      audioCapture: audioCapture,
      asrManager: asrManager,
      transcriptStore: transcriptStore,
      keychainManager: keychainManager,
      captureTelemetry: captureTelemetry,
      pasteCompletionRegistry: polishService.pasteCompletionRegistry
    )
    // W6: wire language-flip telemetry into the detector via a closure so
    // `EnviousWisprASR` (which cannot import PostHog) stays vendor-contained.
    // The detector fires this inline from an actor; we hop to MainActor to
    // call `TelemetryService` (which is @MainActor isolated).
    // The chip handler is wired AFTER init completes (see setPassiveChipHandler
    // call below) because it needs to capture self, and Swift does not allow
    // that before all stored properties are initialized.
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
    whisperKitPipeline = WhisperKitPipeline(
      audioCapture: audioCapture,
      backend: WhisperKitBackend(),
      transcriptStore: transcriptStore,
      keychainManager: keychainManager,
      languageDetector: languageDetector,
      captureTelemetry: captureTelemetry,
      pasteCompletionRegistry: polishService.pasteCompletionRegistry
    )

    // Phase F (#501) — construct SetupCoordinator after asrManager + whisperKitPipeline
    // exist (it needs both — asrManager for activeBackendType reads, the pipeline
    // closure for prepareBackendSilently()). The capture is [weak whisperKitPipeline]
    // so the coordinator does not retain the pipeline.
    setup = SetupCoordinator(
      asrManager: asrManager,
      preloadAction: { [weak whisperKitPipeline] in
        await whisperKitPipeline?.prepareBackendSilently()
      }
    )

    // Initialize settingsSync and apply initial settings to all targets
    settingsSync = PipelineSettingsSync(
      pipeline: pipeline,
      whisperKitPipeline: whisperKitPipeline,
      polishService: polishService,
      audioCapture: audioCapture,
      asrManager: asrManager,
      hotkeyService: hotkeyService,
      whisperKitSetup: setup.whisperKitSetup
    )
    settingsSync.applyInitialSettings(settings)

    recordingOverlay.setGrantHandler { [weak self] in
      _ = self?.permissions.requestAccessibilityAccess()
    }
    recordingOverlay.setAccessibilityWarningDismissedProvider { [weak self] in
      self?.permissions.accessibilityWarningDismissed ?? false
    }

    // Wire dictation activity provider (after all stored properties initialized)
    polishService.setDictationActivity(self)

    // Wire the passive-chip handler on the LanguageDetector actor now that
    // self is fully constructed. The handler hops to MainActor and forwards
    // the trigger to LanguageSuggestionPresenter (set by AppDelegate via
    // attachLanguageSuggestionPresenter). DEBUG-only one-shot warning if the
    // presenter is nil when an event arrives (catches test-harness misuse
    // and refactor regressions; impossible in production AppDelegate flow).
    Task { [weak self] in
      await languageDetector.setPassiveChipHandler { @Sendable (trigger: PassiveChipTrigger) in
        Task { @MainActor in
          guard let self = self else { return }
          ChipWiringDiagnostics.warnIfPresenterMissing(self.languageSuggestionPresenter)
          self.languageSuggestionPresenter?.bufferTrigger(trigger)
        }
      }
    }

    // PR8 of #763 — heart-path event-routing callbacks (seven `audioCapture.on*`
    // closures + `asrManager.onServiceInterrupted` + AVAudioEngineConfigurationChange
    // observer) moved to `DictationRuntime` and its three private routers
    // (`AudioEventRouter`, `ASREventRouter`, `WedgeRecoveryRouter`). Constructed
    // in `EnviousWisprApp.init()` after AppState is constructed. PR9
    // absorbed the resolver helpers + warning Task into the new lifecycle
    // home; routers' injected closures now resolve through it.

    settingsSync.onNeedsPreloadObservation = { [weak setup] in
      setup?.startPreloadObservation()
    }

    // Wire custom-words propagator. The exact ordering (seed → register all
    // consumers → install onWordsChanged) lives in `wireCustomWords` so
    // tests can drive the same path with spy consumers + a real
    // `CustomWordsCoordinator`. Phase D (#496) replaces the prior 5-way
    // fanout in AppState plus 5 mirror sites in `PipelineSettingsSync`.
    wireCustomWords(
      propagator: customWordsPropagator,
      initialWords: customWordsCoordinator.customWords,
      correctorConsumers: [
        pipeline.wordCorrection,
        whisperKitPipeline.wordCorrection,
      ],
      polishConsumers: [
        pipeline.llmPolish,
        whisperKitPipeline.llmPolish,
        polishService.llmPolishStep,
      ],
      coordinator: customWordsCoordinator
    )

    // AppLogger initial seed lives in PipelineSettingsSync.applyInitialSettings
    // (called above at line 238) — single owner for settings-driven side effects.
    // See #728.

    // Restore persisted backend selection synchronously (no race with first record).
    // setInitialBackendType is safe at startup: nothing loaded, no unload needed.
    asrManager.setInitialBackendType(settings.selectedBackend)
    SentryBreadcrumb.updateASRBackend(
      settings.selectedBackend == .whisperKit ? "whisperkit" : "parakeet")

    // Wire settings change handler
    settings.onChange = { [weak self] key in
      guard let self else { return }
      self.settingsSync.handleSettingChanged(key, settings: self.settings)
    }

    // PR9 of #763 — pipeline state-change closures moved to
    // `DictationLifecycleCoordinator.install()`, called once by the
    // composition root (`EnviousWisprApp.init`) after the coordinator is
    // constructed. The coordinator owns: overlay show/clear, hotkey
    // arbitration, telemetry, chip lifecycle, terminal settings sync,
    // backend-resolver state + helpers, post-completion warning Task.

    // Wire hotkey callbacks
    hotkeyService.recordingMode = settings.recordingMode
    hotkeyService.cancelKeyCode = settings.cancelKeyCode
    hotkeyService.cancelModifiers = settings.cancelModifiers
    hotkeyService.toggleKeyCode = settings.toggleKeyCode
    hotkeyService.toggleModifiers = settings.toggleModifiers
    hotkeyService.onToggleRecording = { [weak self] in
      guard let self else { return }
      await self.toggleRecording(source: .toggleHotkey)
    }
    hotkeyService.onStartRecording = { [weak self] in
      guard let self else { return }
      // PR9 of #763 — cancel any pending post-completion warning from the
      // previous session before showing the new recording overlay. Task lives
      // on `DictationLifecycleCoordinator` now; AppState holds a weak ref via
      // `attachDictationLifecycleCoordinator`. PR10 inlines this when start
      // migrates into `RecordingStarter`.
      self.dictationLifecycleCoordinator?.cancelPendingWarning()
      let isWhisperKit = self.asrManager.activeBackendType == .whisperKit
      let active = self.activePipeline

      if isWhisperKit {
        guard !self.whisperKitPipeline.state.isActive else { return }
      } else {
        guard !self.pipeline.state.isActive else { return }
      }
      // PR7 of #763 — clear any prior polish error before the new recording
      // start. Mirrors `toggleRecording(source:)` below. Sunset PR9.
      self.lastRecordingResult?.polishError = nil
      // Refresh AX status so `DictationSessionConfigFactory.make` sees the right
      // paste capability. The session snapshot is captured fresh at
      // `.toggleRecording` dispatch below.
      self.permissions.refreshAccessibilityStatus()
      if !self.permissions.hasAccessibilityPermission {
        self.permissions.restartMonitoringIfNeeded()
      }

      // Show recording overlay IMMEDIATELY for instant visual feedback.
      // The pipeline hasn't started yet, but the user needs to see the
      // overlay now — especially for double-press detection where they
      // need visual confirmation before tapping again.
      self.recordingOverlay.show(
        intent: .recording(audioLevel: 0),
        audioLevelProvider: { self.audioCapture.audioLevel },
        isRecordingLocked: false
      )

      let pttStart = ContinuousClock.now
      do {
        try await active.handle(event: .preWarm)
      } catch is CancellationError {
        // Issue #289: PTT release mid-preWarm threw CancellationError (silent
        // unwind). Not a user-visible failure — just clean up. The existing
        // `Task.isCancelled` guard below no longer fires because the throw
        // short-circuits past it, so this catch is load-bearing.
        self.audioCapture.abortPreWarm()
        self.recordingOverlay.show(intent: .hidden)
        self.isRecordingLocked = false
        return
      } catch {
        // Issue #289: real preWarm failure (XPC transport dead, AVAudioEngine
        // `'what?'`, etc.). Abort the start cleanly — never call
        // `.toggleRecording` against a dead capture path — and surface a brief
        // user-visible error. Telemetry-free here: the lower layers already
        // breadcrumbed the root cause; this is the user-facing UX.
        self.audioCapture.abortPreWarm()
        self.recordingOverlay.show(intent: .hidden)
        self.isRecordingLocked = false
        SentryBreadcrumb.add(
          stage: "recording", message: "preWarm failed — start aborted",
          level: .warning, data: ["error": String(describing: error)]
        )
        active.setExternalError("Microphone unavailable — try again.")
        return
      }
      guard !Task.isCancelled else {
        // Non-throwing cancellation path (e.g. outer Task cancel between
        // preWarm return and .toggleRecording dispatch).
        self.audioCapture.abortPreWarm()
        self.recordingOverlay.show(intent: .hidden)
        self.isRecordingLocked = false
        return
      }
      let preWarmMs = {
        let (s, a) = (ContinuousClock.now - pttStart).components
        return Int(s) * 1000 + Int(a / 1_000_000_000_000_000)
      }()
      // #445 + #585: surface dispatch failures (CancellationError is the silent-unwind
      // case; HeartControlRecovery handles both shapes internally).
      do {
        try await active.handle(
          event: .toggleRecording(
            DictationSessionConfigFactory.make(
              asrManager: self.asrManager,
              pipeline: self.pipeline,
              whisperKitPipeline: self.whisperKitPipeline,
              settings: self.settings,
              triggerSource: .pttHotkey
            )))
      } catch {
        self.heartControlRecovery.recover(
          error: error, pipeline: active, op: "toggle-from-prewarm",
          message: ModelLoadWatchdog.userMessage)
        return
      }
      let totalMs = {
        let (s, a) = (ContinuousClock.now - pttStart).components
        return Int(s) * 1000 + Int(a / 1_000_000_000_000_000)
      }()
      // Issue #445: post-condition guard. If `.handle` returned without putting
      // the pipeline into an active state AND the pipeline didn't already
      // surface its own `.error(...)`, treat as a silent failure and recover.
      // Per Codex Q4: do NOT overwrite an existing `.error(...)` (the watchdog
      // path already set it with the right message); only recover for
      // inactive non-error states.
      let pipelineActive: Bool
      let pipelineInError: Bool
      if isWhisperKit {
        pipelineActive = self.whisperKitPipeline.state.isActive
        if case .error = self.whisperKitPipeline.state {
          pipelineInError = true
        } else {
          pipelineInError = false
        }
      } else {
        pipelineActive = self.pipeline.state.isActive
        if case .error = self.pipeline.state {
          pipelineInError = true
        } else {
          pipelineInError = false
        }
      }
      // Issue #445 / Codex P2: user-initiated stop during this start drives
      // the pipeline to idle through the expected `.requestStop` path, not a
      // wedge. Skip the wedge recovery if a stop request arrived after
      // pttStart — the pipeline is correctly idle for the right reason.
      let userStoppedDuringStart: Bool = {
        guard let lastStop = self.lastUserStopRequest else { return false }
        return lastStop > pttStart
      }()
      if !pipelineActive && !pipelineInError && !userStoppedDuringStart {
        SentryBreadcrumb.captureError(
          ModelLoadWatchdog.WedgeError(stage: "post_condition"),
          category: .pipelinePostConditionFailed, stage: "recording",
          extra: ["backend": isWhisperKit ? "whisperkit" : "parakeet"]
        )
        self.recordingOverlay.show(intent: .hidden)
        self.isRecordingLocked = false
        active.setExternalError(ModelLoadWatchdog.userMessage)
        return
      }
      if !pipelineActive && !pipelineInError && userStoppedDuringStart {
        // Expected stop. Quietly clean up overlay; no error surface.
        self.recordingOverlay.show(intent: .hidden)
        self.isRecordingLocked = false
        return
      }
      Task {
        await AppLogger.shared.log(
          "COLD-START [AppState] PTT-to-recording: total=\(totalMs)ms preWarm=\(preWarmMs)ms startRecording=\(totalMs - preWarmMs)ms backend=\(isWhisperKit ? "whisperkit" : "parakeet")",
          level: .info, category: "Pipeline"
        )
      }
    }
    hotkeyService.onStopRecording = { [weak self] in
      guard let self else { return }
      self.isRecordingLocked = false
      self.lastUserStopRequest = ContinuousClock.now
      // #585: snapshot active pipeline so a backend switch mid-await
      // cannot surface the error on the wrong pipeline's UI.
      let active = self.activePipeline
      do {
        try await active.handle(event: .requestStop)
      } catch {
        self.heartControlRecovery.logDispatchFailure(error, op: "stop")
      }
    }

    hotkeyService.onCancelRecording = { [weak self] in
      self?.isRecordingLocked = false
      self?.lastUserStopRequest = ContinuousClock.now
      await self?.cancelRecording()
    }

    hotkeyService.onIsProcessing = { [weak self] in
      guard let self else { return false }
      // Block during any state that means "still working on the last recording"
      if self.asrManager.activeBackendType == .whisperKit {
        let state = self.whisperKitPipeline.state
        return state == .transcribing || state == .polishing
      } else {
        let state = self.pipeline.state
        return state == .transcribing || state == .polishing
      }
    }

    hotkeyService.onLocked = { [weak self] in
      guard let self else { return }
      self.isRecordingLocked = true
      self.recordingOverlay.updateLockState(true)
      Task {
        await AppLogger.shared.log(
          "Hands-free mode activated — overlay expanding",
          level: .info, category: "AppState"
        )
      }
    }

    // Pre-load the selected backend's model in the background to eliminate cold-start delay.
    // Parakeet: direct silent load (model files already downloaded during onboarding).
    // WhisperKit: observation-based (waits for setupState to become .ready first).
    if settings.selectedBackend == .parakeet {
      Task { [weak self] in
        await self?.asrManager.loadModelSilently()
      }
    }
    Task { [weak self] in
      await self?.setup.whisperKitSetup.detectState()
      self?.setup.startPreloadObservation()
    }

    // NOTE: hotkey registration is deferred to startHotkeyServiceIfEnabled(),
    // called from applicationDidFinishLaunching. Carbon RegisterEventHotKey
    // requires the NSApplication event loop to be running for event delivery.
  }

  /// Start the hotkey service. Must be called after the NSApplication event loop
  /// is running (e.g., from applicationDidFinishLaunching), because Carbon
  /// RegisterEventHotKey events are only delivered once the run loop is active.
  func startHotkeyServiceIfEnabled() {
    if settings.hotkeyEnabled {
      hotkeyService.start()
    }
  }

  /// Active dictation pipeline — routes based on selected backend.
  var activePipeline: any DictationPipeline {
    asrManager.activeBackendType == .whisperKit ? whisperKitPipeline : pipeline
  }

  /// Issue #445: most recent user stop/cancel timestamp; suppresses the
  /// post-condition wedge guard when the user released PTT mid-start.
  private var lastUserStopRequest: ContinuousClock.Instant?

  // PR9 of #763 — backend-resolver state + helpers + the deferred warning
  // scheduler moved to `DictationLifecycleCoordinator`. PR8's DictationRuntime
  // resolver closures now capture the new home instead of AppState. Same-PR
  // grep-test gate (`AppStateNoLongerOwnsBackendResolverTests`) enforces.

  /// Reset the currently active pipeline to idle. Used by UI "dismiss" actions.
  func resetActivePipeline() {
    if asrManager.activeBackendType == .whisperKit {
      whisperKitPipeline.reset()
    } else {
      pipeline.reset()
    }
  }

  /// Toggle recording on/off (plain, no forced LLM).
  ///
  /// `source` distinguishes the invocation surface for `dictation.invoked` telemetry
  /// (issue #723). Production callers MUST specify; there is no default to prevent
  /// silent fallthrough to a generic value.
  func toggleRecording(source: TriggerSource) async {
    // PR9 of #763 — see comment in `hotkeyService.onStartRecording`.
    dictationLifecycleCoordinator?.cancelPendingWarning()
    let active = activePipeline
    // PR7 of #763 — match the hotkey path: clear prior polish error before
    // dispatch when this toggle is a START. Sunset PR9.
    let isWK = asrManager.activeBackendType == .whisperKit
    if !(isWK ? whisperKitPipeline.state.isActive : pipeline.state.isActive) {
      lastRecordingResult?.polishError = nil
    }

    // Refresh AX status before snapshotting — `DictationSessionConfigFactory.make`
    // derives `autoPasteToActiveApp` from the active pipeline's idle state
    // plus the current AX permission.
    permissions.refreshAccessibilityStatus()
    if !permissions.hasAccessibilityPermission {
      permissions.restartMonitoringIfNeeded()
    }

    // #585: surface dispatch failure via Sentry + clear UI lock + visible error
    // on the pipeline. Recovery type handles CancellationError silently.
    do {
      try await active.handle(
        event: .toggleRecording(
          DictationSessionConfigFactory.make(
            asrManager: asrManager,
            pipeline: pipeline,
            whisperKitPipeline: whisperKitPipeline,
            settings: settings,
            triggerSource: source
          )))
    } catch {
      heartControlRecovery.recover(
        error: error, pipeline: active, op: "toggle",
        message: ModelLoadWatchdog.userMessage)
    }
  }

  /// Cancel an active recording, discarding all captured audio.
  func cancelRecording() async {
    TelemetryService.shared.dictationCanceled(
      stage: "recording", reason: "user_cancel", durationSeconds: nil)
    // PR4 of #763 (#252): clear chip state on cancel BEFORE dispatching cancel
    // event. Cancel transitions through .idle (not .error), so the .error arm
    // in pipeline state-change closures alone is insufficient. Sunset in PR10:
    // moves into DictationRuntime.cancel.
    languageSuggestionPresenter?.clearCurrentChip()
    languageSuggestionPresenter?.clearBuffer()
    isRecordingLocked = false
    recordingOverlay.hide()
    let isWhisperKit = asrManager.activeBackendType == .whisperKit
    if isWhisperKit {
      let wkState = whisperKitPipeline.state
      guard wkState == .recording || wkState == .loadingModel || wkState == .startingUp else {
        return
      }
      do {
        try await whisperKitPipeline.handle(event: .cancelRecording)
      } catch {
        heartControlRecovery.logDispatchFailure(error, op: "cancel-whisperkit")
      }
    } else {
      // PR7 of #763 — `pipelineState` getter removed; this branch is Parakeet
      // only (`!isWhisperKit`), so read the concrete pipeline's state directly.
      guard pipeline.state == .recording || pipeline.state == .loadingModel else { return }
      await pipeline.cancelRecording()
    }
  }

  // Phase 5 B.1 validated 2026-03-16: batch round-trip 51-60ms across XPC.
  // Cold model load: 13,966ms. 3 warm back-to-back runs stable.
  // Test function in git history.
}

// MARK: - DictationActivityProviding

extension AppState: DictationActivityProviding {
  /// True when either pipeline is actively recording, transcribing, or polishing.
  /// Used by TranscriptPolishService to prevent concurrent re-polish + live dictation.
  var isDictationActive: Bool {
    pipeline.state.isActive || whisperKitPipeline.state.isActive
  }
}

extension WhisperKitPipelineState {
  /// One authoritative mapping from WhisperKit's 9-state enum to unified PipelineState.
  var asPipelineState: PipelineState {
    switch self {
    case .idle, .ready: return .idle
    case .startingUp, .loadingModel: return .loadingModel
    case .recording: return .recording
    case .transcribing: return .transcribing
    case .polishing: return .polishing
    case .complete: return .complete
    case .error(let msg): return .error(msg)
    }
  }
}
