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
  let benchmark = BenchmarkSuite()
  let recordingOverlay = RecordingOverlayPanel()
  let ollamaSetup = OllamaSetupService()
  let whisperKitSetup = WhisperKitSetupService()
  let audioDeviceList = AudioDeviceList()
  let captureTelemetry = CaptureTelemetryState()

  /// Background task that observes WhisperKitSetupService.setupState and pre-loads the model when ready.
  private var whisperKitPreloadTask: Task<Void, Never>?

  /// Cancellable task for showing a deferred post-completion warning (e.g. polish failed).
  /// Cancelled when a new recording starts or a higher-priority notification is shown.
  private var postCompletionWarningTask: Task<Void, Never>?

  // Pipelines — initialized after sub-systems
  let pipeline: TranscriptionPipeline
  let whisperKitPipeline: WhisperKitPipeline

  // Phase A (#196) — per-pipeline state-change behavior absorbed from the
  // onStateChange closures. Each handler owns the effect execution; AppState
  // still owns the cross-pipeline warning Task + tiebreaker + hotkey ordering.
  // Lazy so the callback closures can capture `self` after stored-property
  // assignment completes. First access is inside `onStateChange`, well after
  // `init()` returns.
  @ObservationIgnored
  private lazy var parakeetStateHandler: PipelineStateChangeHandler = {
    makeStateChangeHandler(backendLabel: "parakeet")
  }()
  @ObservationIgnored
  private lazy var whisperKitStateHandler: PipelineStateChangeHandler = {
    makeStateChangeHandler(backendLabel: "whisperKit")
  }()

  private func makeStateChangeHandler(backendLabel: String) -> PipelineStateChangeHandler {
    PipelineStateChangeHandler(
      showOverlay: { [weak self] intent in
        guard let self else { return }
        self.recordingOverlay.show(
          intent: intent,
          audioLevelProvider: { [weak self] in self?.audioCapture.audioLevel ?? 0 },
          isRecordingLocked: self.isRecordingLocked
        )
      },
      cancelPendingWarning: { [weak self] in self?.postCompletionWarningTask?.cancel() },
      schedulePolishFailedWarning: { [weak self] in
        self?.schedulePostCompletionWarning(message: "Polish failed -- using raw text")
      },
      appendCompletedTranscript: { [weak self] t in self?.transcriptCoordinator.append(t) },
      reportDictationCompleted: { [weak self] t in
        guard let self else { return }
        TelemetryService.shared.reportDictationCompleted(
          transcript: t, inputMode: self.settings.recordingMode.rawValue)
      },
      reportPipelineFailed: { msg in
        TelemetryService.shared.pipelineFailed(
          stage: "transcription", errorCategory: "pipeline_error", errorCode: msg,
          recoverable: false, backend: backendLabel)
      }
    )
  }

  /// Standalone service for re-polishing saved transcripts from the detail view.
  /// Completely decoupled from pipeline state machines.
  let polishService: TranscriptPolishService

  /// Forwards settings changes to pipelines and subsystems.
  private let settingsSync: PipelineSettingsSync

  /// Called when pipeline state changes — set by AppDelegate for icon updates.
  var onPipelineStateChange: ((PipelineState) -> Void)?

  // Transcript history — delegated to coordinator
  let transcriptCoordinator: TranscriptCoordinator
  var pendingNavigationSection: SettingsSection?

  /// True when recording is in hands-free (locked) mode via double-press.
  /// Read by the overlay to switch to the expanded lips visual.
  var isRecordingLocked: Bool = false

  /// Multilingual v1: latest passive-chip trigger emitted by LanguageDetector,
  /// if any. Observed by settings/overlay UI to offer a "Detected X. Lock it?"
  /// or "Language unstable. Lock language?" CTA. Nil when no chip is pending.
  /// UI consumers set this to nil after dismissing.
  /// TODO: wire a settings-level banner that presents this; current v1 ship is
  /// callback-only so chip events are not silently dropped.
  var pendingPassiveChip: PassiveChipTrigger?

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

  init() {
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

    // Phase C (#428) — composition-root for transcript storage.
    // One `TranscriptStore` instance is constructed here and threaded
    // into every consumer (coordinator + both pipelines + polish service).
    // AppState does NOT retain this as a property; each consumer keeps
    // the reference it received via init. No accessor is exposed on the
    // coordinator; no consumer constructs its own. The shared-store
    // invariant is verifiable by grep: exactly one `TranscriptStore(`
    // call in `Sources/` outside `EnviousWisprStorage/TranscriptStore.swift`.
    let transcriptStore = TranscriptStore()
    // Production invariant: the app has always written transcripts to
    // AppConstants.appSupportURL/transcripts. Verified via grep 2026-04-20.
    // No legacy path, no group container, no iCloud. Phase C Invariant
    // safeguard #4 (Option B — plan §11): a concrete migrator would be a
    // no-op, so we rely on the default init's directory-create-on-miss
    // plus founder dogfood (safeguard #3) to catch any future path shift.
    transcriptCoordinator = TranscriptCoordinator(store: transcriptStore)
    llmDiscovery = LLMModelDiscoveryCoordinator(keychainManager: keychainManager)

    // Both pipeline properties must be initialized before `self` can be used.
    // WhisperKitBackend default is large-v3-turbo; reconfigured from settings below.
    pipeline = TranscriptionPipeline(
      audioCapture: audioCapture,
      asrManager: asrManager,
      transcriptStore: transcriptStore,
      keychainManager: keychainManager,
      captureTelemetry: captureTelemetry
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
      captureTelemetry: captureTelemetry
    )
    // Transcript polish service (re-polish from detail view, decoupled from pipelines)
    polishService = TranscriptPolishService(
      keychainManager: keychainManager,
      transcriptStore: transcriptStore
    )

    // Initialize settingsSync and apply initial settings to all targets
    settingsSync = PipelineSettingsSync(
      pipeline: pipeline,
      whisperKitPipeline: whisperKitPipeline,
      polishService: polishService,
      audioCapture: audioCapture,
      asrManager: asrManager,
      hotkeyService: hotkeyService,
      whisperKitSetup: whisperKitSetup
    )
    settingsSync.applyInitialSettings(settings, customWords: customWordsCoordinator.customWords)

    // Wire dictation activity provider (after all stored properties initialized)
    polishService.setDictationActivity(self)

    // Wire the passive-chip handler on the LanguageDetector actor now that
    // self is fully constructed. The handler hops back to the MainActor
    // to publish the chip on `pendingPassiveChip` so UI can observe it.
    Task { [weak self] in
      await languageDetector.setPassiveChipHandler { @Sendable (trigger: PassiveChipTrigger) in
        Task { @MainActor in
          self?.pendingPassiveChip = trigger
        }
      }
    }

    // Unified engine interruption handler — routes to whichever pipeline is actively recording.
    // Both pipelines share the same audioCapture instance. When the audio engine/XPC service
    // is interrupted, we must notify the pipeline that's currently recording, not the one
    // that happened to set onEngineInterrupted last.
    audioCapture.onEngineInterrupted = { [weak self] in
      guard let self else { return }
      let pState = self.pipeline.state
      let wkState = self.whisperKitPipeline.state
      Task {
        await AppLogger.shared.log(
          "[AppState] Audio onEngineInterrupted — parakeet=\(pState), whisperKit=\(wkState)",
          level: .info, category: "XPC"
        )
      }
      SentryBreadcrumb.add(
        stage: "audio", message: "Audio XPC interrupted", level: .error,
        data: [
          "parakeet_state": "\(pState)",
          "whisperkit_state": "\(wkState)",
        ])
      // Issue #285 — route to the pipeline that owns the shared capture
      // right now. Uses the same owner-selection as `activeTelemetryTarget()`
      // so the two paths cannot drift when both pipelines are active
      // (overlap during backend switch: one polishing while the other starts
      // a new recording).
      switch self.activeCaptureBackend() {
      case .parakeet:
        self.pipeline.handleEngineInterruption()
      case .whisperKit:
        self.whisperKitPipeline.handleEngineInterruption()
      case nil:
        break  // neither pipeline active — nothing to clean up
      }
      // Do NOT hide the overlay here. The pipeline's handleEngineInterruption()
      // sets state = .error(...), which fires onStateChange and shows the error
      // overlay. Calling hide() immediately after would dismiss it before the
      // user can read it. The error overlay auto-dismisses after 3 seconds.
    }

    // Issue #285 — XPC transport telemetry. Proxy fires this from its
    // interruption and invalidation handlers; idle interrupts stay silent.
    // We emit a single captureError per channel with enough context for
    // Sentry to classify and alert.
    audioCapture.onXPCServiceError = { [weak self] ctx in
      guard let self else { return }
      let handlerKind: XPCHandlerKind = {
        switch ctx.kind {
        case .interruptCapturing: return .interrupt
        case .invalidateCapturing, .invalidateIdle: return .invalidate
        }
      }()
      let wasCapturing = ctx.kind != .invalidateIdle
      let extras: [String: Any] = [
        "xpc.handler": handlerKind.rawValue,
        "xpc.was_capturing": wasCapturing,
        "xpc.kind": ctx.kind.rawValue,
        "capture_session_id": ctx.sessionID.map { Int($0) } ?? NSNull(),
        "capture.route": self.audioCapture.currentAudioRoute,
      ]
      SentryBreadcrumb.captureError(
        HeartPathError.audioXPCInterrupted(
          handler: handlerKind, wasCapturing: wasCapturing),
        category: .xpcServiceError,
        stage: "audio",
        extra: extras
      )
    }

    // (see `activeTelemetryTarget()` at end of init for dispatch logic).
    // Issue #285 — centralized routing for heart-path telemetry callbacks.
    // `audioCapture` is a single instance shared by both pipelines, so these
    // closure properties are single-owner — per-pipeline wiring would let the
    // last-initialized pipeline silently steal the callbacks. Same pattern as
    // `onEngineInterrupted` above: route to whichever pipeline is currently
    // recording so the right backend's dedup flags get set.
    audioCapture.onCaptureStalled = { [weak self] ctx in
      guard let self, self.isCurrentSession(ctx.sessionID) else { return }
      self.activeTelemetryTarget()?.handleCaptureStall(ctx)
    }
    audioCapture.onXPCReplyFailed = { [weak self] ctx in
      guard let self, self.isCurrentSession(ctx.sessionID) else { return }
      self.activeTelemetryTarget()?.handleXPCReplyFailed(ctx)
    }
    audioCapture.onCaptureSessionInterruption = { [weak self] ctx in
      guard let self, self.isCurrentSession(ctx.sessionID) else { return }
      self.activeTelemetryTarget()?.handleCaptureSessionInterruption(ctx)
    }

    // Observe audio route changes for Sentry context enrichment.
    // AVAudioEngineSource fires AVAudioEngineConfigurationChange internally and handles
    // recovery, but breadcrumbs live in EnviousWisprServices (unavailable in the audio module).
    // AppState observes here to stay within module boundary rules.
    NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.captureTelemetry.incrementConfigChange()
        let route = self.audioCapture.currentAudioRoute
        SentryBreadcrumb.add(
          stage: "audio", message: "Audio route changed", level: .warning,
          data: [
            "audio_route": route
          ])
        SentryBreadcrumb.updateAudioRoute(route)
      }
    }

    // Unified ASR service crash handler — routes to whichever pipeline is active.
    // Fires when the XPC ASR service dies mid-session (streaming or batch).
    asrManager.onServiceInterrupted = { [weak self] in
      guard let self else { return }
      let pState = self.pipeline.state
      let wkState = self.whisperKitPipeline.state
      Task {
        await AppLogger.shared.log(
          "[AppState] ASR onServiceInterrupted — parakeet=\(pState), whisperKit=\(wkState)",
          level: .info, category: "XPC"
        )
      }
      if pState == .loadingModel || pState == .recording || pState == .transcribing {
        self.pipeline.handleASRServiceInterruption()
      } else if wkState == .recording || wkState == .transcribing {
        self.whisperKitPipeline.handleASRServiceInterruption()
      }
      // Do NOT hide the overlay here. Same reasoning as onEngineInterrupted:
      // the pipeline sets .error(...) state which shows the error overlay via
      // onStateChange. The error overlay auto-dismisses after 3 seconds.
    }

    // Unified VAD auto-stop handler — routes to whichever pipeline is actively recording.
    // Fired by service-side VAD (XPC mode only). Same routing pattern as onEngineInterrupted.
    audioCapture.onVADAutoStop = { [weak self] in
      guard let self else { return }
      if self.pipeline.state == .recording {
        Task { await self.pipeline.stopAndTranscribe() }
      } else if self.whisperKitPipeline.state == .recording {
        Task { await self.whisperKitPipeline.stopAndTranscribe() }
      }
    }
    settingsSync.onNeedsPreloadObservation = { [weak self] in
      self?.startWhisperKitPreloadObservation()
    }

    // Wire custom-words propagator. Construction order is non-reversible:
    // 1) seed `propagator.words` with current coordinator words via `update`
    //    (no consumers registered yet, so this is a no-op broadcast that just
    //    captures the seed value)
    // 2) register all five consumers (each receives the seed via `register()`'s
    //    initial-sync path)
    // 3) THEN forward `onWordsChanged` into `propagator.update(_:)` so future
    //    mutations broadcast through the registry.
    customWordsPropagator.update(customWordsCoordinator.customWords)
    customWordsPropagator.register(pipeline.wordCorrection)
    customWordsPropagator.register(pipeline.llmPolish)
    customWordsPropagator.register(whisperKitPipeline.wordCorrection)
    customWordsPropagator.register(whisperKitPipeline.llmPolish)
    customWordsPropagator.register(polishService.llmPolishStep)
    customWordsCoordinator.onWordsChanged = { [weak customWordsPropagator] words in
      customWordsPropagator?.update(words)
    }

    // Initialize logger
    Task {
      await AppLogger.shared.setLogLevel(settings.debugLogLevel)
      await AppLogger.shared.setDebugMode(settings.isDebugModeEnabled)
    }

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

    // Wire pipeline state changes to overlay and icon.
    // The behavioral contract (overlay resolution, warning scheduling /
    // cancellation, telemetry, history reload) is owned by the per-pipeline
    // PipelineStateChangeHandler. The closure still owns AppState-local
    // concerns: external observer fan-out, hotkey register/unregister,
    // isRecordingLocked reset, and the inactive→active tiebreaker (#285).
    pipeline.onStateChange = { [weak self] newState in
      guard let self else { return }
      self.onPipelineStateChange?(newState)
      switch newState {
      case .recording:
        self.hotkeyService.registerCancelHotkey()
      case .loadingModel, .transcribing, .polishing:
        self.isRecordingLocked = false
        self.hotkeyService.unregisterCancelHotkey()
      case .error, .idle, .complete:
        self.isRecordingLocked = false
        self.hotkeyService.unregisterCancelHotkey()
        // Session ended — retry any Ollama eviction deferred because the
        // frozen session pinned the old model.
        self.settingsSync.retryDeferredOllamaEviction(settings: self.settings)
      }
      let nowActive = newState.isActive
      if nowActive && !self.prevParakeetActive {
        self.lastCapturingBackend = .parakeet
      }
      self.prevParakeetActive = nowActive
      self.parakeetStateHandler.handle(
        to: newState,
        pipelineOverlayIntent: self.pipeline.overlayIntent,
        lastPolishError: self.pipeline.lastPolishError,
        currentTranscript: self.pipeline.currentTranscript
      )
    }

    // Wire WhisperKit pipeline state changes to overlay and icon.
    whisperKitPipeline.onStateChange = { [weak self] newState in
      guard let self else { return }
      self.onPipelineStateChange?(self.pipelineState)
      switch newState {
      case .recording:
        self.hotkeyService.registerCancelHotkey()
      case .startingUp, .loadingModel, .transcribing, .polishing:
        self.isRecordingLocked = false
        self.hotkeyService.unregisterCancelHotkey()
      case .error, .idle, .ready, .complete:
        self.isRecordingLocked = false
        self.hotkeyService.unregisterCancelHotkey()
        self.settingsSync.retryDeferredOllamaEviction(settings: self.settings)
      }
      let nowActive = newState.isActive
      if nowActive && !self.prevWhisperKitActive {
        self.lastCapturingBackend = .whisperKit
      }
      self.prevWhisperKitActive = nowActive
      self.whisperKitStateHandler.handle(
        to: newState,
        pipelineOverlayIntent: self.whisperKitPipeline.overlayIntent,
        lastPolishError: self.whisperKitPipeline.lastPolishError,
        currentTranscript: self.whisperKitPipeline.currentTranscript
      )
    }

    // Wire hotkey callbacks
    hotkeyService.recordingMode = settings.recordingMode
    hotkeyService.cancelKeyCode = settings.cancelKeyCode
    hotkeyService.cancelModifiers = settings.cancelModifiers
    hotkeyService.toggleKeyCode = settings.toggleKeyCode
    hotkeyService.toggleModifiers = settings.toggleModifiers
    hotkeyService.onToggleRecording = { [weak self] in
      guard let self else { return }
      await self.toggleRecording()
    }
    hotkeyService.onStartRecording = { [weak self] in
      guard let self else { return }
      // Cancel any pending post-completion warning from the previous session
      // before showing the new recording overlay.
      self.postCompletionWarningTask?.cancel()
      let isWhisperKit = self.asrManager.activeBackendType == .whisperKit
      let active = self.activePipeline

      if isWhisperKit {
        guard !self.whisperKitPipeline.state.isActive else { return }
      } else {
        guard !self.pipelineState.isActive else { return }
      }

      // Refresh AX status so `makeDictationSessionConfig` sees the right
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
      // `.toggleRecording` is declared throws on the protocol, but today the
      // underlying implementation doesn't throw. `try?` keeps the surface
      // unchanged. If a future event grows a meaningful throw we revisit here.
      try? await active.handle(event: .toggleRecording(makeDictationSessionConfig()))
      let totalMs = {
        let (s, a) = (ContinuousClock.now - pttStart).components
        return Int(s) * 1000 + Int(a / 1_000_000_000_000_000)
      }()
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
      try? await self.activePipeline.handle(event: .requestStop)
    }

    hotkeyService.onCancelRecording = { [weak self] in
      self?.isRecordingLocked = false
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
      await self?.whisperKitSetup.detectState()
      self?.startWhisperKitPreloadObservation()
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

  /// Observe WhisperKitSetupService.setupState and pre-load the model when it becomes .ready.
  /// Uses withObservationTracking to react to @Observable property changes outside SwiftUI.
  private func startWhisperKitPreloadObservation() {
    whisperKitPreloadTask?.cancel()
    whisperKitPreloadTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }

        // Exit immediately when WhisperKit isn't the active backend. Parakeet
        // users shouldn't pay CPU/memory cost warming a backend they never use.
        // Backend switches fire settingsSync.onNeedsPreloadObservation, which
        // restarts this observer; the re-entry sees the new activeBackendType.
        guard self.asrManager.activeBackendType == .whisperKit else { return }

        // Check current state — if already .ready, trigger pre-load
        let currentState = self.whisperKitSetup.setupState
        if currentState == .ready {
          await self.whisperKitPipeline.prepareBackendSilently()
          return  // Model loaded — no need to keep observing
        }

        // Wait for the next change to setupState
        await withCheckedContinuation { continuation in
          withObservationTracking {
            _ = self.whisperKitSetup.setupState
          } onChange: {
            continuation.resume()
          }
        }
      }
    }
  }

  /// Active dictation pipeline — routes based on selected backend.
  var activePipeline: any DictationPipeline {
    asrManager.activeBackendType == .whisperKit ? whisperKitPipeline : pipeline
  }

  /// Convenience: current pipeline state — routes through active backend.
  var pipelineState: PipelineState {
    if asrManager.activeBackendType == .whisperKit {
      return whisperKitPipeline.state.asPipelineState
    }
    return pipeline.state
  }

  /// Last polish error from the active pipeline.
  var lastPolishError: String? {
    if asrManager.activeBackendType == .whisperKit {
      return whisperKitPipeline.lastPolishError
    }
    return pipeline.lastPolishError
  }

  /// Convenience: the transcript from the latest recording.
  var activeTranscript: Transcript? {
    if let selected = transcriptCoordinator.selectedTranscriptID {
      return transcriptCoordinator.transcripts.first { $0.id == selected }
    }
    if asrManager.activeBackendType == .whisperKit {
      return whisperKitPipeline.currentTranscript
    }
    return pipeline.currentTranscript
  }

  /// Schedule a deferred post-completion warning overlay. Cancellable and session-scoped:
  /// cancelled if a new recording starts (any non-complete state change cancels it).
  /// Uses the pipeline's current state as a guard to avoid showing stale warnings.
  /// Issue #285 — which backend most recently entered an active state
  /// (startup, loading, or recording). Used as a tiebreaker when both
  /// pipelines are active simultaneously (e.g. one still polishing while the
  /// other begins a new capture). Updated on any active-state entry, not just
  /// `.recording`, so stall watchdog and interruption callbacks that fire
  /// pre-recording resolve to the correct backend.
  private enum LastCapturingBackend { case parakeet, whisperKit }
  private var lastCapturingBackend: LastCapturingBackend = .parakeet
  // Previous active-state of each pipeline, tracked so we flip
  // `lastCapturingBackend` only on inactive→active transitions. Without this,
  // `.transcribing → .polishing` (active → active) would re-steal ownership
  // after a different backend acquired the shared capture.
  private var prevParakeetActive: Bool = false
  private var prevWhisperKitActive: Bool = false

  /// Issue #285 — resolve which backend owns the shared audio capture right
  /// now. Returns nil when both pipelines are fully idle. Shared helper for
  /// both telemetry routing and engine-interrupt routing so the two paths
  /// cannot drift.
  private func activeCaptureBackend() -> LastCapturingBackend? {
    let pActive = pipeline.state.isActive
    let wkActive = whisperKitPipeline.state.isActive
    if pActive && wkActive { return lastCapturingBackend }
    if pActive { return .parakeet }
    if wkActive { return .whisperKit }
    return nil
  }

  /// Issue #285 — belt-and-suspenders filter for late callbacks that somehow
  /// slip past the per-source `isCapturing` / observer-removal guards during a
  /// backend switch. Dropping a stale callback is safer than misrouting it to
  /// a new session's dedup state. Source-level guards normally catch this;
  /// this is a second line of defense for the backend-overlap window.
  private func isCurrentSession(_ sessionID: UInt64) -> Bool {
    sessionID == audioCapture.currentCaptureSessionID
  }

  private func activeTelemetryTarget() -> (any HeartPathTelemetryTarget)? {
    switch activeCaptureBackend() {
    case .whisperKit: return whisperKitPipeline
    case .parakeet: return pipeline
    case nil:
      // Idle → attribute to the backend that most recently owned a session.
      return lastCapturingBackend == .whisperKit ? whisperKitPipeline : pipeline
    }
  }

  private func schedulePostCompletionWarning(message: String) {
    postCompletionWarningTask?.cancel()
    postCompletionWarningTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, let self else { return }
      // Only show if we're still in the completed state (no new recording started)
      let parakeetComplete = self.pipeline.state == .complete
      let whisperKitComplete =
        self.whisperKitPipeline.state == .complete || self.whisperKitPipeline.state == .ready
      guard parakeetComplete || whisperKitComplete else { return }
      self.recordingOverlay.show(intent: .warning(message: message))
    }
  }

  /// Reset the currently active pipeline to idle. Used by UI "dismiss" actions.
  func resetActivePipeline() {
    if asrManager.activeBackendType == .whisperKit {
      whisperKitPipeline.reset()
    } else {
      pipeline.reset()
    }
  }

  /// Convenience: audio level for UI visualization.
  var audioLevel: Float {
    audioCapture.audioLevel
  }

  /// Human-readable model name for display.
  var activeModelName: String {
    settings.selectedBackend == .parakeet ? "Parakeet v3" : "WhisperKit"
  }

  var activeLLMDisplayName: String {
    guard settings.llmProvider != .none else { return "LLM Deactivated" }
    let model = settings.llmProvider == .ollama ? settings.ollamaModel : settings.llmModel
    if model.isEmpty { return settings.llmProvider.displayName }
    // Use discoveredModels displayName if available, otherwise raw model ID
    if let info = llmDiscovery.discoveredModels.first(where: { $0.id == model }) {
      return info.displayName
    }
    return model
  }

  /// Model status text for sidebar display.
  var modelStatusText: String {
    if asrManager.activeBackendType == .whisperKit {
      switch whisperKitPipeline.state {
      case .loadingModel: return "Loading Model"
      case .recording: return "Recording"
      case .transcribing: return "Transcribing"
      case .polishing: return "Polishing"
      case .error: return "Error"
      default: break
      }
    } else {
      if pipelineState == .recording { return "Recording" }
      if pipelineState == .transcribing { return "Transcribing" }
      if pipelineState == .polishing { return "Polishing" }
      if case .error = pipelineState { return "Error" }
    }
    return asrManager.isModelLoaded ? "Loaded" : "Unloaded"
  }

  /// Toggle recording on/off (plain, no forced LLM).
  func toggleRecording() async {
    postCompletionWarningTask?.cancel()
    let active = activePipeline

    // Refresh AX status before snapshotting — `makeDictationSessionConfig`
    // derives `autoPasteToActiveApp` from the active pipeline's idle state
    // plus the current AX permission.
    permissions.refreshAccessibilityStatus()
    if !permissions.hasAccessibilityPermission {
      permissions.restartMonitoringIfNeeded()
    }

    // Fire dictation.invoked telemetry when starting (not stopping).
    // Intent event: captures user action before engine/ASR work begins.
    // Check that the active pipeline is NOT already in a recording/processing state.
    let alreadyActive: Bool
    if active is WhisperKitPipeline {
      let s = whisperKitPipeline.state
      alreadyActive =
        s == .recording || s == .transcribing || s == .polishing || s == .loadingModel
        || s == .startingUp
    } else {
      let s = pipeline.state
      alreadyActive = s == .recording || s == .transcribing || s == .polishing || s == .loadingModel
    }
    if !alreadyActive {
      let targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
      TelemetryService.shared.dictationInvoked(
        triggerSource: settings.recordingMode.rawValue,
        inputMode: settings.recordingMode.rawValue,
        targetApp: targetApp
      )
    }

    try? await active.handle(event: .toggleRecording(makeDictationSessionConfig()))
  }

  /// Build the per-recording `DictationSessionConfig` snapshot. Captures the
  /// current `SettingsManager` state plus the input-mode-derived paste intent.
  /// Called at `.toggleRecording` dispatch; the recording's pipeline freezes
  /// the snapshot for its lifetime via `startRecording(config:)`.
  private func makeDictationSessionConfig() -> DictationSessionConfig {
    let isWhisperKit = asrManager.activeBackendType == .whisperKit
    let activePipelineIdle: Bool = {
      if isWhisperKit {
        switch whisperKitPipeline.state {
        case .idle, .ready, .complete, .error: return true
        default: return false
        }
      } else {
        switch pipeline.state {
        case .idle, .complete, .error: return true
        default: return false
        }
      }
    }()
    let autoPaste = activePipelineIdle && permissions.hasAccessibilityPermission
    let resolvedModel: String = {
      switch settings.llmProvider {
      case .appleIntelligence: return "apple-intelligence"
      case .ollama: return settings.ollamaModel
      default: return settings.llmModel
      }
    }()
    return DictationSessionConfig(
      autoCopyToClipboard: settings.autoCopyToClipboard,
      autoPasteToActiveApp: autoPaste,
      restoreClipboardAfterPaste: settings.restoreClipboardAfterPaste,
      vadAutoStop: settings.vadAutoStop,
      vadSilenceTimeout: settings.vadSilenceTimeout,
      vadSensitivity: settings.vadSensitivity,
      vadEnergyGate: settings.vadEnergyGate,
      languageMode: settings.languageMode,
      useStreamingASR: settings.useStreamingASR,
      modelUnloadPolicy: settings.modelUnloadPolicy,
      llmProvider: settings.llmProvider,
      llmModel: resolvedModel,
      polishInstructions: settings.activePolishInstructions,
      styleConfig: settings.activePolishStyleConfig,
      useExtendedThinking: settings.useExtendedThinking,
      selectedInputDeviceUID: settings.selectedInputDeviceUID,
      preferredInputDeviceIDOverride: settings.preferredInputDeviceIDOverride
    )
  }

  /// Cancel an active recording, discarding all captured audio.
  func cancelRecording() async {
    TelemetryService.shared.dictationCanceled(
      stage: "recording", reason: "user_cancel", durationSeconds: nil)
    isRecordingLocked = false
    recordingOverlay.hide()
    let isWhisperKit = asrManager.activeBackendType == .whisperKit
    if isWhisperKit {
      let wkState = whisperKitPipeline.state
      guard wkState == .recording || wkState == .loadingModel || wkState == .startingUp else {
        return
      }
      try? await whisperKitPipeline.handle(event: .cancelRecording)
    } else {
      guard pipelineState == .recording || pipelineState == .loadingModel else { return }
      await pipeline.cancelRecording()
    }
  }

  /// Enhancement error from the transcript detail view's re-polish service.
  /// Separate from `lastPolishError` which tracks live-dictation polish failures.
  var lastEnhancementError: EnhancementError? {
    polishService.lastEnhancementError
  }

  /// Re-polish an existing transcript via the standalone polish service.
  /// Decoupled from pipeline state: does not touch pipeline.state, currentTranscript, or lastPolishError.
  func polishTranscript(_ transcript: Transcript) async {
    do {
      let updated = try await polishService.polish(transcript)
      if let idx = transcriptCoordinator.transcripts.firstIndex(where: { $0.id == updated.id }) {
        transcriptCoordinator.transcripts[idx] = updated
      }
      // Ensure detail view refreshes even when activeTranscript falls back to pipeline.currentTranscript
      transcriptCoordinator.selectedTranscriptID = updated.id
    } catch {
      // Error already captured in polishService.lastEnhancementError
      Task {
        await AppLogger.shared.log(
          "Transcript enhancement failed: \(error.localizedDescription)",
          level: .info, category: "Enhancement"
        )
      }
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
