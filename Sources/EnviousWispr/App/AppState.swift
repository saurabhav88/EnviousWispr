import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import SwiftUI

/// Root observable state for the entire application.
///
/// PR10 of #763 — recording-control surface (`toggleRecording`,
/// `cancelRecording`, `resetActivePipeline`, `startHotkeyServiceIfEnabled`,
/// `hotkeyService` collaborator, the `lazy var heartControlRecovery`, the
/// `var lastUserStopRequest` post-condition-guard timestamp, the
/// `dictationLifecycleCoordinator` weak ref + setter, and the hotkey
/// callback wiring block) moved to `DictationRuntime` and its three
/// new private collaborators (`HotkeyController` / `RecordingStarter` /
/// `RecordingFinalizer`). AppState's init now takes `hotkeyService` so
/// the shared instance still threads into `PipelineSettingsSync`.
/// `var isRecordingLocked` stays here as a vestigial setter target
/// through PR10 (read+written via PR9's `RecordingLockedAccess` struct
/// passed into Starter+Finalizer+DLC); PR11 absorbs it with the host.
/// `extension AppState: DictationActivityProviding` also stays through
/// PR10 (PR11 sunsets it with the host).
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
  // `DictationLifecycleCoordinator` under DictationRuntime.
  //
  // PR10 of #763 — start / stop / cancel / hotkey callback wiring all moved
  // to `DictationRuntime` and its three new private collaborators
  // (`HotkeyController` / `RecordingStarter` / `RecordingFinalizer`).
  // `hotkeyService` no longer lives on AppState; the App owns the shared
  // instance as `@State` and threads it into all consumers.

  /// Standalone service for re-polishing saved transcripts from the detail view.
  /// Completely decoupled from pipeline state machines.
  let polishService: TranscriptPolishService

  /// Forwards settings changes to pipelines and subsystems.
  let settingsSync: PipelineSettingsSync

  /// True when recording is in hands-free (locked) mode via double-press.
  /// Read by the overlay to switch to the expanded lips visual.
  ///
  /// PR10 of #763 — the writers (Starter, Finalizer, the hotkey-onLocked
  /// path) moved to `DictationRuntime`. This var stays as a vestigial
  /// setter target through PR10, accessed via PR9's `RecordingLockedAccess`
  /// get/set struct passed into DLC + Starter + Finalizer. PR11 absorbs
  /// this var with the AppState host.
  var isRecordingLocked: Bool = false

  /// PR4 of #763 (#252 fold-in): the chip presenter is set via setter
  /// injection by AppDelegate after both AppState and the presenter exist.
  /// PR10 moved the cancel-path chip-clear call site into `RecordingFinalizer`;
  /// AppState no longer dispatches chip lifecycle. PR11 deletes AppState
  /// (and this reference along with it).
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
  /// error state. PR9's `DictationLifecycleCoordinator` owns the state-change
  /// push sites; PR10 moved the start-path resets into `RecordingStarter`.
  /// AppState no longer reads or writes this directly.
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

  /// PR9 of #763 — `transcriptStore` is constructed by the composition root
  /// (`EnviousWisprApp.init`) and injected.
  ///
  /// PR10 of #763 — `hotkeyService` is constructed by the composition root
  /// as `@State` so it can be shared with `HotkeyController` (callback
  /// wiring), `DictationLifecycleCoordinator` (per-pipeline cancel-hotkey
  /// register/unregister), `PipelineSettingsSync` (live key/modifier/mode
  /// updates), and `AppDelegate.attach(...)` (termination `.stop()`).
  /// AppState passes the shared instance straight through to PSS without
  /// holding a reference itself.
  init(transcriptStore: TranscriptStore, hotkeyService: HotkeyService) {
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
    // (`AudioEventRouter`, `ASREventRouter`, `WedgeRecoveryRouter`).
    // PR9 absorbed the resolver helpers + warning Task into the new lifecycle
    // home; PR10 absorbed the hotkey callback wiring + start/stop/cancel.

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
    // (called above) — single owner for settings-driven side effects.
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
    // constructed.

    // PR10 of #763 — hotkey callback wiring + start/stop/cancel paths moved
    // to `DictationRuntime` and its three new private collaborators
    // (`HotkeyController` / `RecordingStarter` / `RecordingFinalizer`).
    // DR.init builds the recording subsystem and calls
    // `hotkeyController.install()` internally as the last init step.

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
