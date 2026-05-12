import AppKit
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

// R2 (#360): the pipeline holds no WhisperKit-typed values after the
// Approach C session protocol + LID-button refactor, so it no longer
// imports the vendor module directly. The dependency is also dropped from
// the EnviousWisprPipeline target in `Package.swift`. All vendor reach now
// goes through `EnviousWisprASR`'s package-access seams.

/// Internal state machine for the WhisperKit highway — independent of PipelineState.
public enum WhisperKitPipelineState: Equatable, Sendable {
  case idle
  case startingUp  // engine warm-up / pre-capture setup
  case loadingModel
  case ready
  case recording
  case transcribing
  case polishing
  case complete
  case error(String)

  public var isActive: Bool {
    switch self {
    case .startingUp, .recording, .transcribing, .polishing, .loadingModel:
      return true
    default:
      return false
    }
  }
}

// MARK: - PipelineStateProtocol conformance

extension WhisperKitPipelineState: PipelineStateProtocol {
  public var activity: PipelineActivity {
    switch self {
    case .idle, .ready: return .idle
    case .startingUp, .loadingModel: return .preparing
    case .recording: return .recording
    case .transcribing, .polishing: return .processing
    case .complete: return .complete
    case .error(let msg): return .error(msg)
    }
  }
}

/// Independent WhisperKit dictation pipeline — batch record → transcribe → polish → paste.
///
/// Owns its own 8-state machine, shares only AudioCaptureManager and LLM infrastructure
/// with the Parakeet highway (TranscriptionPipeline). No streaming — batch only.
@MainActor
@Observable
public final class WhisperKitPipeline: DictationPipeline, HeartPathTelemetryTarget {
  private let audioCapture: any AudioCaptureInterface
  private let backend: WhisperKitBackend
  private let keychainManager: KeychainManager

  public private(set) var state: WhisperKitPipelineState = .idle {
    didSet {
      // Honor the `currentSessionConfig` contract: nil when no recording is
      // in flight. `.ready` is terminal for pipeline activity — the backend
      // is warm but the user hasn't asked for a session yet. Clear BEFORE
      // firing `onStateChange` so observer code (`reconcileOllamaEviction`)
      // sees the cleared session and is not blocked by a stale pin. (#426)
      switch state {
      case .idle, .ready, .complete, .error:
        currentSessionConfig = nil
      case .startingUp, .loadingModel, .recording, .transcribing, .polishing:
        break
      }
      if state != oldValue {
        onStateChange?(state)
      }
    }
  }
  public var onStateChange: ((WhisperKitPipelineState) -> Void)?
  public private(set) var currentTranscript: Transcript?
  public var lastPolishError: String?

  /// Per-recording session config snapshot. Captured at `startRecording`; immutable
  /// for the duration of the recording. Settings mutated mid-recording apply to the
  /// NEXT recording. `nil` when no recording is in flight.
  public private(set) var currentSessionConfig: DictationSessionConfig?

  // MARK: - Session-scoped accessors (backed by `currentSessionConfig`)

  private var autoCopyToClipboard: Bool { currentSessionConfig?.autoCopyToClipboard ?? true }
  private var autoPasteToActiveApp: Bool { currentSessionConfig?.autoPasteToActiveApp ?? false }
  private var restoreClipboardAfterPaste: Bool {
    currentSessionConfig?.restoreClipboardAfterPaste ?? false
  }
  private var modelUnloadPolicy: ModelUnloadPolicy {
    currentSessionConfig?.modelUnloadPolicy ?? .never
  }
  /// Frozen language mode for the active recording. Mid-record Auto/Locked
  /// toggles no longer reach the in-flight session — intentional behavior
  /// change documented in `DictationSessionConfig` and the #195 plan.
  private var languageMode: LanguageMode { currentSessionConfig?.languageMode ?? .auto }

  /// Decode-time options. Mutable within a recording because LID results can
  /// overwrite `.language`. Re-derived from `config.languageMode` at each
  /// `startRecording`.
  private var transcriptionOptions: TranscriptionOptions = .default

  private let languageDetector: LanguageDetector
  /// Last detection result, exposed for telemetry and UI (passive chip).
  public private(set) var lastLanguageDetection: LanguageDetectionResult?

  // Shared services
  private let transcriptFinalizer: TranscriptFinalizer

  /// App-wide capture telemetry state (shared with Parakeet pipeline). Owns
  /// dedupe for zombie-engine events (#302) and the AVAudioEngineConfigurationChange
  /// counter (#294 smoking-gun diagnostic).
  private let captureTelemetry: CaptureTelemetryState

  /// Issue #285 dedup state moved to `HeartPathTelemetryEmitter` (#290 R5).
  /// Pipeline delegates the four shared infrastructure events + zombie zero-peak
  /// to `telemetry`; engine-internal telemetry (model load, LID, batch failures)
  /// stays in this file by design.
  private let telemetry: HeartPathTelemetryEmitter

  // Text processing steps (own instances — not shared with Parakeet)
  public let wordCorrectionStep = WordCorrectionStep()
  public let fillerRemovalStep = FillerRemovalStep()
  public let llmPolishStep: LLMPolishStep
  private var textProcessingSteps: [any TextProcessingStep] = []

  /// Access for configuration
  public var wordCorrection: WordCorrectionStep { wordCorrectionStep }
  public var fillerRemoval: FillerRemovalStep { fillerRemovalStep }
  public var llmPolish: LLMPolishStep { llmPolishStep }

  /// The app that was frontmost when recording started.
  private var targetApp: NSRunningApplication?
  private var targetElement: AXUIElement?
  private var recordingStartTime: Date?
  /// Guards against concurrent stopAndTranscribe calls.
  private var isStopping = false
  /// Whether audio input has been pre-warmed by PTT key-down.
  private var isPreWarmed = false

  // VAD properties — frozen per recording in `currentSessionConfig`.
  private var vadAutoStop: Bool { currentSessionConfig?.vadAutoStop ?? false }
  private var vadSilenceTimeout: Double { currentSessionConfig?.vadSilenceTimeout ?? 1.5 }
  private var vadSensitivity: Float { currentSessionConfig?.vadSensitivity ?? 0.5 }
  private var vadEnergyGate: Bool { currentSessionConfig?.vadEnergyGate ?? false }

  private var silenceDetector: SilenceDetector?
  private var vadMonitorTask: Task<Void, Never>?
  /// Frozen snapshot of recording state, built before teardown for post-recording error enrichment.
  private var frozenSnapshot: SentryBreadcrumb.RecordingSnapshot?
  private var incrementalWorker: (any WhisperKitIncrementalSession)?
  private var modelUnloadTask: Task<Void, Never>?
  /// Issue #445: held task wrapping `backend.prepare()` so the watchdog can
  /// cancel the host await on timeout. Cancel here is best-effort (CoreML's
  /// `MLModel.load` does not observe Swift cooperative cancellation), but
  /// `WhisperKitBackend.prepare()` has its own single-flight guard so the
  /// orphaned in-flight load is not duplicated by a subsequent press.
  private var prepareTask: Task<Void, Error>?

  /// Issue #289 stall-recovery ownership token (see TranscriptionPipeline).
  private var pendingStallRecoveryToken: UInt64?

  public init(
    audioCapture: any AudioCaptureInterface,
    backend: WhisperKitBackend,
    transcriptStore: TranscriptStore,
    keychainManager: KeychainManager,
    languageDetector: LanguageDetector = LanguageDetector(),
    captureTelemetry: CaptureTelemetryState = CaptureTelemetryState(),
    pasteCompletionRegistry: PasteCompletionRegistry? = nil
  ) {
    self.audioCapture = audioCapture
    self.backend = backend
    self.keychainManager = keychainManager
    self.languageDetector = languageDetector
    self.captureTelemetry = captureTelemetry
    self.telemetry = HeartPathTelemetryEmitter(
      backend: .whisperKit,
      captureTelemetry: captureTelemetry
    )
    self.transcriptFinalizer = TranscriptFinalizer(
      transcriptStore: transcriptStore,
      pasteCompletionRegistry: pasteCompletionRegistry
    )
    self.llmPolishStep = LLMPolishStep(keychainManager: keychainManager)
    // Explicit engine identity: prevents a future codepath that skips the
    // language detector from silently falling through to the legacy
    // English-centric prompt path. The planner reads `.whisperKit` + nil
    // detection as low-confidence (formatting only, no lexical injection).
    llmPolishStep.backend = .whisperKit

    llmPolishStep.onWillProcess = { [weak self] in
      self?.state = .polishing
    }

    // Engine interruption cleanup is wired by AppState.onEngineInterrupted
    // (unified handler that routes to the active pipeline). The pipeline exposes
    // handleEngineInterruption() for AppState to call.

    // Activate SSE streaming for Gemini
    llmPolishStep.onToken = { _ in }
    textProcessingSteps = [wordCorrectionStep, fillerRemovalStep, llmPolishStep]

    // Issue #285 — telemetry callbacks on `audioCapture` are single-owner
    // properties and both pipelines share the same instance. `AppState`
    // centralizes routing to the active pipeline.
  }

  public func handleCaptureSessionInterruption(_ ctx: CaptureSessionInterruptionContext) {
    telemetry.captureSessionInterrupted(ctx: ctx)
  }

  public func handleXPCReplyFailed(_ ctx: XPCReplyFailureContext) {
    telemetry.xpcReplyFailed(ctx: ctx)
  }

  public func handleCaptureStall(_ ctx: CaptureStallContext) {
    let fired = telemetry.stallFired(
      ctx: ctx,
      isActivelyCapturing: audioCapture.isActivelyCapturing
    )

    // Issue #289: synchronous terminal-state flip before any await — see
    // TranscriptionPipeline.handleCaptureStall for the race-closure rationale.
    // The emitter's per-session dedup already suppressed the captureError on
    // re-entry; we still must guard the state flip the same way.
    guard fired else { return }
    guard state == .recording else { return }
    isPreWarmed = false
    recordingStartTime = nil
    pendingStallRecoveryToken = ctx.sessionID
    state = .error("No audio detected — try again.")

    Task { @MainActor [weak self, sessionID = ctx.sessionID] in
      await self?.finishStallRecovery(for: sessionID)
    }
  }

  /// Issue #289: token-gated cleanup (mirrors `TranscriptionPipeline`).
  /// See TranscriptionPipeline.finishStallRecovery for the sessionID-stale
  /// race that the token gate closes.
  @MainActor
  private func finishStallRecovery(for sessionID: UInt64) async {
    // Defense-in-depth (see TranscriptionPipeline).
    guard case .error = state else { return }
    guard pendingStallRecoveryToken == sessionID else { return }
    guard audioCapture.currentCaptureSessionID == sessionID else { return }
    pendingStallRecoveryToken = nil
    vadMonitorTask?.cancel()
    vadMonitorTask = nil
    await incrementalWorker?.cancel()
    incrementalWorker = nil
    _ = await audioCapture.stopCapture()
  }

  private func emitNoAudioCapturedEvent() {
    let sessionID = audioCapture.currentCaptureSessionID
    let durationMs: Int = {
      guard let start = recordingStartTime else { return 0 }
      return Int(Date().timeIntervalSince(start) * 1000)
    }()
    telemetry.noAudioCaptured(
      ctx: NoAudioContext(
        sessionID: sessionID,
        durationMs: durationMs,
        wasStreaming: false,
        route: audioCapture.currentAudioRoute,
        isActivelyCapturing: audioCapture.isActivelyCapturing,
        captureSourceType: audioCapture.captureSourceType,
        inputDeviceUIDPreferred: audioCapture.preferredInputDeviceIDOverride.isEmpty
          ? nil : audioCapture.preferredInputDeviceIDOverride,
        inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID()
      )
    )
  }

  // MARK: - DictationPipeline Conformance

  public var overlayIntent: OverlayIntent {
    switch state {
    case .startingUp:
      return .processing(label: "Starting...")
    case .loadingModel:
      return .processing(label: "Loading model...")
    case .recording:
      return .recording(audioLevel: 0)
    case .transcribing:
      return .processing(label: "Transcribing...")
    case .polishing:
      return .processing(label: "Polishing...")
    case .idle, .ready, .complete:
      return .hidden
    case .error(let msg):
      if msg == InterruptionMessages.micDisconnected {
        return .interruption(message: msg)
      }
      return .error(message: msg)
    }
  }

  public func handle(event: PipelineEvent) async throws {
    switch event {
    case .preWarm:
      try await preWarmAudioInput()
    case .toggleRecording(let config):
      await toggleRecording(config: config)
    case .requestStop:
      await requestStop()
    case .cancelRecording:
      await cancelRecording()
    case .reset:
      reset()
    }
  }

  /// Issue #289: dumb external-error sink (mirrors `TranscriptionPipeline`).
  public func setExternalError(_ message: String) {
    currentTranscript = nil
    state = .error(message)
  }

  /// Issue #289: see `DictationPipeline.clearPendingStallRecovery`.
  public func clearPendingStallRecovery() {
    pendingStallRecoveryToken = nil
  }

  // MARK: - Background Pre-load

  /// Silently load the WhisperKit model into RAM without changing pipeline state.
  /// Called after model download completes or on launch if model is already cached.
  /// Uses prepareIfCached() to avoid triggering a silent network download.
  /// If user presses record before this finishes, startRecording() handles it with its own .loadingModel flow.
  public func prepareBackendSilently() async {
    let isBackendReady = await backend.isReady
    guard !isBackendReady else { return }
    do {
      let loaded = try await backend.prepareIfCached()
      if loaded {
        Task {
          await AppLogger.shared.log(
            "WhisperKit model pre-loaded successfully (background)",
            level: .info, category: "WhisperKitPipeline"
          )
        }
      } else {
        Task {
          await AppLogger.shared.log(
            "WhisperKit model not cached, skipping silent pre-load",
            level: .info, category: "WhisperKitPipeline"
          )
        }
      }
    } catch {
      Task {
        await AppLogger.shared.log(
          "WhisperKit model pre-load failed: \(error.localizedDescription)",
          level: .info, category: "WhisperKitPipeline"
        )
      }
    }
  }

  // MARK: - Recording Lifecycle

  public func preWarmAudioInput() async throws {
    guard !state.isActive, state != .recording else { return }
    // Issue #289: earliest new-attempt signal — see TranscriptionPipeline
    // for rationale. Clearing in `startRecording` alone left a race window.
    pendingStallRecoveryToken = nil
    let start = ContinuousClock.now
    // Issue #289: propagate preWarm failures (see TranscriptionPipeline).
    try await audioCapture.preWarm()
    guard !Task.isCancelled else { return }
    isPreWarmed = true
    let totalMs = PipelineUtils.durationMs(ContinuousClock.now - start)
    Task {
      await AppLogger.shared.log(
        "COLD-START [WhisperKit] preWarmAudioInput total=\(totalMs)ms",
        level: .info, category: "Pipeline"
      )
    }
    // Defense-in-depth: ensure model is loaded from cache (no download).
    // If not cached, startRecording() handles the full load with user-visible UI.
    Task { _ = try? await backend.prepareIfCached() }
  }

  /// Toggle recording: start if idle, stop if recording. On start transitions,
  /// the provided session config is captured; on stop transitions the config
  /// is ignored.
  public func toggleRecording(config: DictationSessionConfig) async {
    switch state {
    case .idle, .ready, .complete, .error:
      await startRecording(config: config)
    case .recording:
      logLIDReleaseSignpost()
      await stopAndTranscribe()
    case .loadingModel, .startingUp, .transcribing, .polishing:
      break
    }
  }

  /// Guards against concurrent startRecording calls (e.g., rapid toggle presses).
  private var isStarting = false

  public func startRecording(config: DictationSessionConfig) async {
    currentSessionConfig = config
    applySessionConfig(config)
    // Issue #289: new attempt takes ownership — invalidate any pending stall
    // recovery token so an in-flight cleanup cannot tear down this session.
    pendingStallRecoveryToken = nil
    guard !isStarting else { return }
    guard !state.isActive || state == .complete || state == .ready else { return }
    isStarting = true
    defer { isStarting = false }

    // Cancel any pending model unload — keep model loaded during recording.
    modelUnloadTask?.cancel()
    modelUnloadTask = nil

    state = .startingUp
    lastPolishError = nil
    SentryBreadcrumb.add(stage: "whisperkit", message: "Pipeline starting up")

    // Load model if not ready
    let isBackendReady = await backend.isReady
    guard state == .startingUp else { return }  // cancelled during await

    if !isBackendReady {
      state = .loadingModel
      SentryBreadcrumb.add(stage: "asr", message: "WhisperKit model loading")
      // Issue #445: WhisperKit's `MLModel.load` is a black box with no
      // progress signal source — there is nothing the signal-based watcher
      // can observe. The parked branch's 20-second wall-clock wrap is reverted
      // here because it has the indefensible-number problem the rule forbids.
      // Wedge coverage for WhisperKit needs a different signal source (XPC
      // service heartbeat or process-state observation) and is a separate
      // design. The held `prepareTask` and `WhisperKitBackend.resetLoadState`
      // are still useful for cancellation hygiene from `cancelRecording()`,
      // so keep them — just no watchdog race here.
      let captured = backend
      let task = Task<Void, Error> {
        try await captured.prepare()
      }
      prepareTask = task
      do {
        try await task.value
        prepareTask = nil
        guard state == .loadingModel else { return }  // cancelled during model load
        state = .startingUp  // back to startingUp for engine setup
      } catch {
        prepareTask = nil
        if error is CancellationError {
          // Cancelled (e.g. by cancelRecording during load). Return to idle.
          state = .idle
          return
        }
        SentryBreadcrumb.captureError(
          error, category: .modelLoadFailed, stage: "asr", extra: ["backend": "whisperKit"])
        state = .error("Model load failed: \(error.localizedDescription)")
        return
      }
    }

    // Capture target app for paste-back
    targetApp = NSWorkspace.shared.frontmostApplication
    targetElement = PasteService.captureFocusedElement()

    // No streaming buffer forwarding for batch mode
    audioCapture.onBufferCaptured = nil

    do {
      if !isPreWarmed {
        try await audioCapture.startEnginePhase()
        let stabilized = await audioCapture.waitForFormatStabilization(
          maxWait: 1.5,
          pollInterval: 0.2
        )
        guard state == .startingUp else { return }  // cancelled during stabilization
        if !stabilized {
          audioCapture.rebuildEngine()
          try await audioCapture.startEnginePhase()
        }
      }
      isPreWarmed = false

      _ = try await audioCapture.beginCapturePhase()
      state = .recording
      recordingStartTime = Date()
      currentTranscript = nil
      TelemetryService.shared.dictationInvoked(
        triggerSource: config.inputMode.rawValue,
        inputMode: config.inputMode.rawValue,
        targetApp: targetApp?.localizedName
      )
      SentryBreadcrumb.add(
        stage: "recording", message: "WhisperKit recording started", data: ["backend": "whisperKit"]
      )
      SentryBreadcrumb.updateRecordingState(active: true, backend: "whisperkit")
      SentryBreadcrumb.updateAudioRoute(audioCapture.currentAudioRoute)
      startVADMonitoring()
      // Multilingual v1: the incremental worker snapshots transcriptionOptions.language
      // at recording start. In .auto mode, language is unknown until LID runs at
      // recording stop, so the worker would decode with the stale/legacy language.
      // Skip the worker in .auto mode; batch decode at finalize picks up the
      // post-LID language. .locked mode is safe because the language is known upfront.
      let workerEnabled: Bool
      if case .locked = languageMode {
        workerEnabled = true
        await startIncrementalWorker()
      } else {
        workerEnabled = false
      }

      Task { [workerEnabled] in
        await AppLogger.shared.log(
          "WhisperKit recording started (batch mode, incremental worker: \(workerEnabled ? "on" : "off, auto language mode"))",
          level: .info, category: "WhisperKitPipeline"
        )
      }
    } catch {
      let extras = AudioCaptureFailureExtras.build(
        error: error,
        audioCapture: audioCapture,
        failureMode: "thrown_start",
        backend: "whisperKit"
      )
      SentryBreadcrumb.captureError(
        error, category: .audioCaptureFailed, stage: "recording", extra: extras)
      state = .error("Recording failed: \(error.localizedDescription)")
    }
  }

  public func requestStop() async {
    logLIDReleaseSignpost()
    switch state {
    case .recording:
      await stopAndTranscribe()
    case .startingUp, .loadingModel:
      // Clean abort — startRecording() checks state after each await suspension point.
      state = .idle
    case .idle, .ready, .complete, .error:
      // PTT release before recording started — clean up pre-warmed audio engine
      if isPreWarmed {
        isPreWarmed = false
        audioCapture.abortPreWarm()
      }
    case .transcribing, .polishing:
      // Pipeline is past the point of no return — ignore.
      break
    }
  }

  public func stopAndTranscribe() async {
    guard state == .recording, !isStopping else { return }
    isStopping = true
    defer { isStopping = false }

    let pipelineStart = CFAbsoluteTimeGetCurrent()

    // Discard accidental short recordings
    if let startTime = recordingStartTime {
      let elapsed = Date().timeIntervalSince(startTime)
      if elapsed < TimingConstants.minimumRecordingDuration {
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
        await incrementalWorker?.cancel()
        incrementalWorker = nil
        _ = await audioCapture.stopCapture()
        recordingStartTime = nil
        state = .idle
        Task {
          await AppLogger.shared.log(
            "WhisperKit recording too short (\(String(format: "%.2f", elapsed))s), discarded",
            level: .info, category: "WhisperKitPipeline"
          )
        }
        return
      }
    }
    // Freeze snapshot BEFORE teardown — post-recording errors use this instead of live scope.
    let snapshotStartTime = recordingStartTime ?? Date()
    let durationMs = Int(Date().timeIntervalSince(snapshotStartTime) * 1000)
    frozenSnapshot = SentryBreadcrumb.RecordingSnapshot(
      backend: "whisperkit",
      audioRoute: audioCapture.currentAudioRoute,
      wasStreaming: false,
      startTime: snapshotStartTime,
      durationMs: durationMs,
      targetAppBundleID: targetApp?.bundleIdentifier
    )

    recordingStartTime = nil
    vadMonitorTask?.cancel()
    vadMonitorTask = nil

    let captureResult = await audioCapture.stopCapture()
    let rawSamples = captureResult.samples
    SentryBreadcrumb.add(
      stage: "recording", message: "WhisperKit recording stopped",
      data: ["sample_count": rawSamples.count])
    SentryBreadcrumb.updateRecordingState(active: false)

    // Pre-warm LLM backend while ASR runs
    LLMNetworkSession.shared.preWarmModel(
      provider: llmPolishStep.llmProvider,
      model: llmPolishStep.llmModel,
      keychainManager: keychainManager
    )

    guard !rawSamples.isEmpty else {
      emitNoAudioCapturedEvent()
      state = .error("No audio captured")
      return
    }

    // Post-capture VAD routing: ASR gets raw audio + segment metadata; LID keeps
    // the current voiced-only filtered buffer.
    let speechSegments: [SpeechSegment]
    var lidSamples: [Float]
    var asrSamples = rawSamples
    var hasSpeechEvidence = false
    var vadSegmentCount = 0
    var vadSpeechDurationMs = 0
    let isXPCMode = audioCapture is AudioCaptureProxy
    if isXPCMode {
      // XPC mode: VAD segments returned atomically with samples from stopCapture() (#226).
      let segments = captureResult.vadSegments
      speechSegments = segments
      hasSpeechEvidence = WhisperKitPipelineSpeechRouting.hasSpeechEvidence(vadSegments: segments)
      vadSegmentCount = segments.count
      vadSpeechDurationMs =
        segments.reduce(0) { $0 + ($1.endSample - $1.startSample) } * 1000 / 16000
      if !segments.isEmpty {
        lidSamples = SampleFilter.filter(from: rawSamples, segments: segments)
        let loggedLIDSamples = lidSamples
        let pct = String(
          format: "%.1f", Double(loggedLIDSamples.count) / Double(max(rawSamples.count, 1)) * 100)
        Task {
          await AppLogger.shared.log(
            "WhisperKit VAD (XPC): \(vadSegmentCount) speech segments, totalVoicedMs=\(vadSpeechDurationMs), asrSamples=raw(\(rawSamples.count)), lidSamples=\(loggedLIDSamples.count) (\(pct)% voiced)",
            level: .info, category: "WhisperKitPipeline"
          )
        }
      } else {
        lidSamples = rawSamples
      }
    } else if let detector = silenceDetector {
      await detector.finalizeSegments(totalSampleCount: rawSamples.count)
      let segments = await detector.speechSegments
      speechSegments = segments
      hasSpeechEvidence = WhisperKitPipelineSpeechRouting.hasSpeechEvidence(vadSegments: segments)
      vadSegmentCount = segments.count
      vadSpeechDurationMs =
        segments.reduce(0) { $0 + ($1.endSample - $1.startSample) } * 1000 / 16000
      lidSamples = await detector.filterSamples(from: rawSamples)
      let loggedLIDSamples = lidSamples
      let pct = String(
        format: "%.1f", Double(loggedLIDSamples.count) / Double(max(rawSamples.count, 1)) * 100)
      Task {
        await AppLogger.shared.log(
          "WhisperKit VAD: \(vadSegmentCount) speech segments, totalVoicedMs=\(vadSpeechDurationMs), asrSamples=raw(\(rawSamples.count)), lidSamples=\(loggedLIDSamples.count) (\(pct)% voiced)",
          level: .info, category: "WhisperKitPipeline"
        )
      }
    } else {
      speechSegments = []
      lidSamples = rawSamples
      // No VAD detector available -- default to true so empty ASR results
      // still fire Sentry errors (fail toward visibility).
      hasSpeechEvidence = WhisperKitPipelineSpeechRouting.hasSpeechEvidence(vadSegments: nil)
    }
    let peakAudioLevel = rawSamples.reduce(Float(0)) { max($0, abs($1)) }

    // VAD gate: if no speech was detected, skip ASR entirely.
    // Prevents noise-induced hallucinations from ambient sounds.
    if !hasSpeechEvidence {
      if let worker = incrementalWorker {
        await worker.cancel()
        incrementalWorker = nil
      }
      SentryBreadcrumb.add(
        stage: "asr", message: "VAD gate: no speech detected, skipping WhisperKit ASR",
        level: .info,
        data: [
          "backend": "whisperKit",
          "raw_sample_count": rawSamples.count,
          "peak_audio_level": peakAudioLevel,
        ]
      )
      emitZombieEngineEventIfNeeded(rawSamples: rawSamples, peakAudioLevel: peakAudioLevel)
      frozenSnapshot = nil
      state = .idle
      Task {
        await AppLogger.shared.log(
          "VAD gate: no speech, skipping WhisperKit ASR (samples=\(rawSamples.count), peak=\(String(format: "%.4f", peakAudioLevel)))",
          level: .info, category: "WhisperKitPipeline"
        )
      }
      return
    }

    let minimumSamples = AudioConstants.minimumTranscriptionSamples
    let vadFilteredSampleCount = lidSamples.count
    asrSamples = WhisperKitPipelineSpeechRouting.paddedASRSamples(
      rawSamples: rawSamples,
      minimumSamples: minimumSamples
    )
    lidSamples = WhisperKitPipelineSpeechRouting.paddedLIDSamples(
      filteredSamples: lidSamples,
      rawSamples: rawSamples,
      minimumSamples: minimumSamples
    )
    transcriptionOptions = WhisperKitPipelineSpeechRouting.transcriptionOptions(
      from: transcriptionOptions,
      speechSegments: speechSegments
    )
    let voicedDurationSec = Double(vadSpeechDurationMs) / 1000.0
    let lidWindowCount = WhisperKitPipelineSpeechRouting.lidWindowCount(
      forVoicedDuration: voicedDurationSec
    )
    let clipKind = lidWindowCount == 1 ? "short" : "normal"
    var asrEmptyDiagnostics = ASREmptyResultDiagnostics(
      backend: "whisperKit",
      hasSpeechEvidence: hasSpeechEvidence,
      rawSampleCount: rawSamples.count,
      vadSegmentCount: vadSegmentCount,
      vadSpeechDurationMs: vadSpeechDurationMs,
      peakAudioLevel: peakAudioLevel,
      vadFilteredSampleCount: vadFilteredSampleCount,
      finalSampleCount: asrSamples.count,
      samplesPaddedToMinimum: rawSamples.count > 0 && rawSamples.count < minimumSamples,
      usedRawFallbackAfterVAD: false,
      batchRescueAttempted: false,
      speechSegments: speechSegments
    )

    state = .transcribing
    logLIDPerfSignpost(
      "t_state_flip",
      timestamp: CFAbsoluteTimeGetCurrent(),
      sessionID: audioCapture.currentCaptureSessionID,
      voicedDuration: voicedDurationSec,
      lidWindowCount: lidWindowCount,
      clipKind: clipKind
    )

    // Multilingual v1 (W2): detect language on voiced audio before transcribe.
    // Heart protection: detector never throws; if it abstains, pass nil to
    // TranscriptionOptions.language so WhisperKit's internal LID runs.
    // languageMode comes from the frozen DictationSessionConfig captured at
    // startRecording (Phase B refactor, PR #424); mid-recording user toggles
    // are NOT applied to the in-flight session by design.
    // R2 (#360): closure-based observer. The non-Sendable WhisperKit handle
    // stays inside the backend's actor isolation; only the Sendable
    // LIDObservationBatch crosses to the LanguageDetector classifier.
    // The previous unsafe-Sendable workaround is gone.
    // Snapshot `lidSamples` into an immutable binding so the @Sendable observer
    // closure does not capture the surrounding `var lidSamples` (would race).
    let observerSamples = lidSamples
    let lidResult = await languageDetector.detect(
      samples: lidSamples,
      voicedDuration: voicedDurationSec,
      observerFn: { [backend] in
        await backend.observeLID(samples: observerSamples, maxWindows: lidWindowCount)
      },
      mode: languageMode
    )
    logLIDPerfSignpost(
      "t_lid_settled",
      timestamp: CFAbsoluteTimeGetCurrent(),
      sessionID: audioCapture.currentCaptureSessionID,
      voicedDuration: voicedDurationSec,
      lidWindowCount: lidWindowCount,
      clipKind: clipKind
    )
    lastLanguageDetection = lidResult
    // Multilingual v1 (W3): forward the detection to the polish step so the
    // prompt planner can apply confidence-tiered, language-aware vocab
    // injection. Heart-protected: the planner degrades gracefully when the
    // detection is abstained or low-confidence.
    llmPolishStep.languageDetection = lidResult
    if let lang = lidResult.lang, !lidResult.abstained {
      transcriptionOptions.language = lang
    } else {
      // Abstain: let WhisperKit's own LID run. Heart still completes.
      transcriptionOptions.language = nil
    }
    Task {
      await AppLogger.shared.log(
        "LID result: lang=\(lidResult.lang ?? "nil") tier=\(lidResult.tier) conf=\(String(format: "%.2f", lidResult.confidence)) margin=\(String(format: "%.2f", lidResult.margin)) voiced=\(String(format: "%.2f", lidResult.voicedDuration))s abstained=\(lidResult.abstained)",
        level: .info, category: "WhisperKitPipeline"
      )
    }
    SentryBreadcrumb.add(
      stage: "asr", message: "Language detected",
      data: [
        "lang": lidResult.lang ?? "nil",
        "tier": lidResult.tier.rawValue,
        "confidence": String(format: "%.3f", lidResult.confidence),
        "margin": String(format: "%.3f", lidResult.margin),
        "voiced_s": String(format: "%.2f", lidResult.voicedDuration),
        "abstained": lidResult.abstained,
      ])

    // Multilingual v1 (W6): emit language.detected for every LID call and
    // language.lid_abstained when abstaining. Fire-and-forget; telemetry is a
    // limb and must never block transcription.
    let sessionPreferredSnapshot = await languageDetector.peekMemory().sessionPreferred
    TelemetryService.shared.trackLanguageDetected(
      lang: lidResult.lang,
      confidence: lidResult.confidence,
      margin: lidResult.margin,
      voicedDuration: lidResult.voicedDuration,
      abstained: lidResult.abstained,
      sessionPreferredLang: sessionPreferredSnapshot,
      usedSticky: lidResult.usedSessionPrior,
      lidWindowCount: lidWindowCount
    )
    if lidResult.abstained {
      // Classify the abstain reason per spec § Telemetry table.
      let reason: String
      if lidResult.voicedDuration < LanguageDetectorThresholds.shortClipMinSec {
        reason = "too_short"
      } else if lidResult.confidence < LanguageDetectorThresholds.normalProb {
        reason = "low_confidence"
      } else if lidResult.margin < LanguageDetectorThresholds.normalMargin {
        reason = "narrow_margin"
      } else {
        reason = "low_confidence"
      }
      TelemetryService.shared.trackLIDAbstained(
        voicedDuration: lidResult.voicedDuration,
        top1Prob: lidResult.confidence,
        top1Lang: lidResult.lang,
        reason: reason
      )
    }

    SentryBreadcrumb.add(
      stage: "asr", message: "WhisperKit transcription started", data: ["backend": "whisperKit"])

    do {
      let asrStart = CFAbsoluteTimeGetCurrent()

      // Try background worker result first, batch fallback if stale/empty
      let asrText: String
      let asrLanguage: String?
      var usedIncremental = false

      if let worker = incrementalWorker {
        let segments = await silenceDetector?.speechSegments ?? []
        let result = await worker.finalize(finalSamples: rawSamples, speechSegments: segments)
        incrementalWorker = nil
        asrEmptyDiagnostics.incrementalAccepted = result.accepted
        asrEmptyDiagnostics.incrementalResultChars =
          result.text?.trimmingCharacters(in: .whitespacesAndNewlines).count
        asrEmptyDiagnostics.incrementalDecodeCount = result.decodeCount
        asrEmptyDiagnostics.incrementalSamplesCovered = result.samplesCovered
        asrEmptyDiagnostics.incrementalStrategy = result.strategy
        asrEmptyDiagnostics.incrementalMode = result.mode
        asrEmptyDiagnostics.incrementalTailDecodeMs = result.tailDecodeMs

        let coveragePct =
          rawSamples.count > 0
          ? String(format: "%.1f", Double(result.samplesCovered) / Double(rawSamples.count) * 100)
          : "0"

        if result.accepted, let text = result.text,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          asrText = text.trimmingCharacters(in: .whitespacesAndNewlines)
          asrLanguage = transcriptionOptions.language
          usedIncremental = true

          Task {
            await AppLogger.shared.log(
              "WhisperKit finalize: strategy=\(result.strategy), mode=\(result.mode), "
                + "decodes=\(result.decodeCount), tailDecodeMs=\(result.tailDecodeMs), "
                + "coverage=\(result.samplesCovered)/\(rawSamples.count) (\(coveragePct)%)",
              level: .info, category: "WhisperKitPipeline"
            )
          }
        } else {
          Task {
            await AppLogger.shared.log(
              "WhisperKit finalize: strategy=\(result.strategy), "
                + "workerDecodes=\(result.decodeCount), workerCoverage=\(coveragePct)%, "
                + "falling back to batch",
              level: .info, category: "WhisperKitPipeline"
            )
          }

          let batchStart = CFAbsoluteTimeGetCurrent()
          logLIDPerfSignpost(
            "t_asr_start",
            timestamp: batchStart,
            sessionID: audioCapture.currentCaptureSessionID,
            voicedDuration: voicedDurationSec,
            lidWindowCount: lidWindowCount,
            clipKind: clipKind
          )
          let batchResult = try await backend.transcribe(
            audioSamples: asrSamples, options: transcriptionOptions)
          let batchEnd = CFAbsoluteTimeGetCurrent()
          asrEmptyDiagnostics.batchRescueAttempted = true
          asrEmptyDiagnostics.batchRescueResultChars =
            batchResult.text.trimmingCharacters(in: .whitespacesAndNewlines).count
          logLIDPerfSignpost(
            "t_asr_end",
            timestamp: batchEnd,
            sessionID: audioCapture.currentCaptureSessionID,
            voicedDuration: voicedDurationSec,
            lidWindowCount: lidWindowCount,
            clipKind: clipKind
          )
          let batchMs = Int((batchEnd - batchStart) * 1000)
          asrText = batchResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
          asrLanguage = batchResult.language

          Task {
            await AppLogger.shared.log(
              "WhisperKit finalize: strategy=\(result.strategy), batchMs=\(batchMs), "
                + "workerDecodes=\(result.decodeCount), workerCoverage=\(coveragePct)%",
              level: .info, category: "WhisperKitPipeline"
            )
          }
        }
      } else {
        logLIDPerfSignpost(
          "t_asr_start",
          timestamp: CFAbsoluteTimeGetCurrent(),
          sessionID: audioCapture.currentCaptureSessionID,
          voicedDuration: voicedDurationSec,
          lidWindowCount: lidWindowCount,
          clipKind: clipKind
        )
        let batchResult = try await backend.transcribe(
          audioSamples: asrSamples, options: transcriptionOptions)
        asrEmptyDiagnostics.batchRescueAttempted = false
        asrEmptyDiagnostics.batchRescueResultChars =
          batchResult.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        logLIDPerfSignpost(
          "t_asr_end",
          timestamp: CFAbsoluteTimeGetCurrent(),
          sessionID: audioCapture.currentCaptureSessionID,
          voicedDuration: voicedDurationSec,
          lidWindowCount: lidWindowCount,
          clipKind: clipKind
        )
        asrText = batchResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        asrLanguage = batchResult.language
      }

      let asrEnd = CFAbsoluteTimeGetCurrent()

      // Multilingual v1 (W6): per-transcription latency event for the
      // per-language performance dashboard. Emitted only when we actually
      // produced text (empty-result cases are covered by asr.completed +
      // pipeline.failed elsewhere). Audio duration is derived from the raw
      // capture buffer (16kHz mono) so latency is compared against actual
      // recording length, not the VAD-trimmed slice.
      let asrLatencySec = asrEnd - asrStart
      let audioDurationSec = Double(rawSamples.count) / Double(AudioConstants.sampleRate)
      if !asrText.isEmpty && audioDurationSec > 0 {
        let msPerAudioSec = (asrLatencySec * 1000.0) / audioDurationSec
        let modelName = await backend.modelVariantName
        TelemetryService.shared.trackTranscriptionLatency(
          lang: asrLanguage,
          model: modelName,
          durationSeconds: asrLatencySec,
          msPerAudioSecond: msPerAudioSec
        )
      }

      guard !asrText.isEmpty else {
        if hasSpeechEvidence {
          // Real ASR failure: VAD detected speech but decoder returned nothing
          SentryBreadcrumb.captureError(
            NSError(
              domain: "EnviousWispr", code: -1,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "WhisperKit ASR returned empty text despite speech evidence"
            ]),
            category: .asrEmptyResult, stage: "asr",
            extra: {
              var extra = asrEmptyDiagnostics.sentryExtra()
              extra["incremental"] = usedIncremental
              return extra
            }(),
            snapshot: frozenSnapshot
          )
          state = .error("Couldn't catch that -- try again")
          Task {
            await AppLogger.shared.log(
              "WhisperKit ASR empty despite speech evidence (segments=\(vadSegmentCount), speechMs=\(vadSpeechDurationMs), peak=\(peakAudioLevel))",
              level: .info, category: "WhisperKitPipeline"
            )
          }
        } else {
          // Expected: user held button without speaking
          SentryBreadcrumb.add(
            stage: "asr", message: "WhisperKit ASR empty (no speech detected)",
            level: .info,
            data: ["backend": "whisperKit", "incremental": usedIncremental]
          )
          state = .idle
          Task {
            await AppLogger.shared.log(
              "WhisperKit: no speech detected, returning to idle",
              level: .info, category: "WhisperKitPipeline"
            )
          }
        }
        frozenSnapshot = nil
        return
      }

      SentryBreadcrumb.add(
        stage: "asr", message: "WhisperKit ASR completed",
        data: [
          "duration_s": String(format: "%.3f", asrEnd - asrStart),
          "char_count": asrText.count,
          "incremental": usedIncremental,
        ])
      Task {
        await AppLogger.shared.log(
          "WhisperKit ASR completed in \(String(format: "%.3f", asrEnd - asrStart))s "
            + "(\(asrText.count) chars, lang=\(asrLanguage ?? "?"), incremental=\(usedIncremental))",
          level: .info, category: "WhisperKitPipeline"
        )
      }

      // Post-ASR finalization: text processing -> store -> paste
      let recordingDuration = Double(rawSamples.count) / 16000.0
      let finalizationResult: FinalizationResult
      do {
        finalizationResult = try await transcriptFinalizer.finalize(
          FinalizationRequest(
            asrText: asrText,
            language: asrLanguage,
            duration: recordingDuration,
            processingTime: asrEnd - asrStart,
            backendType: .whisperKit,
            targetApp: targetApp,
            targetElement: targetElement,
            autoCopyToClipboard: autoCopyToClipboard,
            autoPasteToActiveApp: autoPasteToActiveApp,
            restoreClipboardAfterPaste: restoreClipboardAfterPaste,
            steps: textProcessingSteps
          ))
        logLIDPerfSignpost(
          "t_clipboard_write",
          timestamp: CFAbsoluteTimeGetCurrent(),
          sessionID: audioCapture.currentCaptureSessionID,
          voicedDuration: voicedDurationSec,
          lidWindowCount: lidWindowCount,
          clipKind: clipKind
        )
      } catch is CancellationError {
        frozenSnapshot = nil
        return
      } catch let error as FinalizationError {
        switch error {
        case .emptyAfterProcessing:
          SentryBreadcrumb.captureError(
            HeartPathError.emptyAfterProcessing(
              route: audioCapture.currentAudioRoute,
              wasPolishEnabled: llmPolishStep.isEnabled
            ),
            category: .heartPathFinalization,
            stage: "processing",
            extra: [
              "capture.route": audioCapture.currentAudioRoute,
              "polish.enabled": llmPolishStep.isEnabled,
              "backend": "whisperKit",
              "capture_session_id": Int(audioCapture.currentCaptureSessionID),
            ]
          )
          state = .error("No text after processing")
          frozenSnapshot = nil
          return
        case .storageFailed(let underlying):
          SentryBreadcrumb.captureError(underlying, category: .asrFailed, stage: "storage")
          state = .error("Failed to save transcript")
          frozenSnapshot = nil
          return
        }
      }

      lastPolishError = finalizationResult.polishError

      // Build metrics (pipeline-specific: uses ASR timing)
      let pasteTargetApp = targetApp?.bundleIdentifier
      targetApp = nil
      targetElement = nil

      let pipelineEnd = CFAbsoluteTimeGetCurrent()
      let polishDuration = finalizationResult.polishDurationSeconds
      let pasteDuration = finalizationResult.pasteDurationSeconds
      Task {
        await AppLogger.shared.log(
          "WhisperKit pipeline TOTAL: \(String(format: "%.3f", pipelineEnd - pipelineStart))s "
            + "(ASR=\(String(format: "%.3f", asrEnd - asrStart))s, "
            + "polish=\(String(format: "%.3f", polishDuration))s, "
            + "paste=\(String(format: "%.3f", pasteDuration))s)",
          level: .info, category: "WhisperKitPipeline"
        )
      }

      var transcript = finalizationResult.transcript
      transcript.metrics = ExecutionMetrics(
        asrLatencySeconds: asrEnd - asrStart,
        llmLatencySeconds: polishDuration,
        pasteTier: finalizationResult.pasteResult?.pasteTierLabel,
        pasteLatencyMs: finalizationResult.pasteResult?.durationMs,
        targetApp: pasteTargetApp,
        coldStart: false,
        streamingMode: false,
        e2eSeconds: pipelineEnd - pipelineStart,
        polishRouterMode: finalizationResult.polishMetadata?.routerMode,
        polishRouterBasis: finalizationResult.polishMetadata?.routerBasis,
        polishFilterTripped: finalizationResult.polishMetadata?.filterTripped,
        polishFellBackToRaw: finalizationResult.polishMetadata == nil
          ? nil : finalizationResult.pipelineFellBackToRaw
      )
      currentTranscript = transcript
      SentryBreadcrumb.add(
        stage: "pipeline", message: "WhisperKit pipeline complete",
        data: [
          "e2e_s": String(format: "%.3f", pipelineEnd - pipelineStart),
          "asr_s": String(format: "%.3f", asrEnd - asrStart),
          "polish_s": String(format: "%.3f", polishDuration),
          "paste_tier": finalizationResult.pasteResult?.pasteTierLabel ?? "none",
        ])
      captureTelemetry.recordSuccessfulRecording()
      frozenSnapshot = nil
      // Schedule unload BEFORE the terminal transition — the `state` didSet
      // clears `currentSessionConfig` on entry to `.complete`, and the
      // unload policy is read from that snapshot.
      scheduleModelUnloadIfNeeded()
      state = .complete
    } catch {
      SentryBreadcrumb.captureError(
        error, category: .asrFailed, stage: "transcription", extra: ["backend": "whisperKit"],
        snapshot: frozenSnapshot)
      frozenSnapshot = nil
      state = .error("Transcription failed: \(error.localizedDescription)")
    }
  }

  /// Handle audio engine interruption (device disconnect, service crash, max duration cap).
  /// Called by AppState's unified interruption handler, not set directly on audioCapture.
  public func handleEngineInterruption() {
    pendingStallRecoveryToken = nil
    // Issue #285 — Sentry emission for audio/XPC interruptions is owned by
    // AppState.onXPCServiceError (single-owner per plan §3.4a). Control-flow
    // cleanup only.
    SentryBreadcrumb.updateRecordingState(active: false)
    frozenSnapshot = nil
    vadMonitorTask?.cancel()
    vadMonitorTask = nil
    silenceDetector = nil
    // Reset capture state so isCapturing and warm engine timer are consistent.
    Task { [weak self] in
      _ = await self?.audioCapture.stopCapture()
    }
    targetApp = nil
    targetElement = nil
    recordingStartTime = nil
    isStopping = false
    isPreWarmed = false
    state = .error("Microphone disconnected")
  }

  /// Handle ASR XPC service crash during active session.
  /// Called by AppState's unified ASR interruption handler when this pipeline is active.
  /// Must stop audio capture (still running — only ASR died) and clean up fully.
  public func handleASRServiceInterruption() {
    pendingStallRecoveryToken = nil
    let snapshot = buildInterruptionSnapshot()
    SentryBreadcrumb.captureError(
      NSError(
        domain: "EnviousWispr", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "ASR XPC service crashed (WhisperKit)"]),
      category: .xpcServiceError, stage: "asr",
      extra: ["was_recording": state == .recording, "backend": "whisperKit"],
      snapshot: snapshot
    )
    SentryBreadcrumb.updateRecordingState(active: false)
    frozenSnapshot = nil
    vadMonitorTask?.cancel()
    vadMonitorTask = nil
    silenceDetector = nil
    Task { [weak self] in
      await self?.audioCapture.stopCapture()
    }
    targetApp = nil
    targetElement = nil
    recordingStartTime = nil
    isStopping = false
    isPreWarmed = false
    state = .error("Transcription service crashed — please try again")
  }

  private func buildInterruptionSnapshot() -> SentryBreadcrumb.RecordingSnapshot {
    if let existing = frozenSnapshot { return existing }
    let start = recordingStartTime ?? Date()
    return SentryBreadcrumb.RecordingSnapshot(
      backend: "whisperkit",
      audioRoute: audioCapture.currentAudioRoute,
      wasStreaming: false,
      startTime: start,
      durationMs: Int(Date().timeIntervalSince(start) * 1000),
      targetAppBundleID: targetApp?.bundleIdentifier
    )
  }

  public func cancelRecording() async {
    pendingStallRecoveryToken = nil
    if state == .startingUp || state == .loadingModel {
      // Cancel during startup or model load — transition to idle.
      // Issue #445: also cancel the held prepare task so its host await
      // unwinds. Backend's single-flight guard handles any orphan that
      // continues running because CoreML's load is uncancellable.
      prepareTask?.cancel()
      prepareTask = nil
      state = .idle
      return
    }

    guard state == .recording else { return }
    vadMonitorTask?.cancel()
    vadMonitorTask = nil
    await incrementalWorker?.cancel()
    incrementalWorker = nil
    silenceDetector = nil
    _ = await audioCapture.stopCapture()
    targetApp = nil
    targetElement = nil
    recordingStartTime = nil
    state = .idle
  }

  public func reset() {
    pendingStallRecoveryToken = nil
    vadMonitorTask?.cancel()
    vadMonitorTask = nil
    // Issue #445: clean up any held prepare task on reset (cleanup symmetry
    // for the watchdog flow). Backend's single-flight prevents duplicate
    // loads even if the orphan keeps grinding.
    prepareTask?.cancel()
    prepareTask = nil
    // Fire-and-forget cancel — reset() is synchronous, worker cancel is safe to defer
    if let worker = incrementalWorker {
      incrementalWorker = nil
      Task { await worker.cancel() }
    }
    silenceDetector = nil
    if audioCapture.isCapturing {
      let capture = audioCapture
      Task { _ = await capture.stopCapture() }
    }
    audioCapture.onBufferCaptured = nil
    recordingStartTime = nil
    state = .idle
    currentTranscript = nil
  }

  // MARK: - Incremental Worker

  private func startIncrementalWorker() async {
    // R2 (#360): vended via opaque session protocol so Pipeline holds no
    // WhisperKit-specific type. Returns nil iff the backend's WhisperKit
    // model is unloaded (same gating as the legacy reach this replaced).
    guard let session = await backend.makeIncrementalSession(options: transcriptionOptions)
    else { return }
    self.incrementalWorker = session

    let isXPCMode = audioCapture is AudioCaptureProxy
    let capture = audioCapture

    if isXPCMode {
      // XPC mode: use getSamplesSnapshot for incremental sample access.
      // Tracks fromIndex locally — each call fetches only new samples since last snapshot.
      //
      // Memory: `accumulated` grows linearly with recording duration, mirroring the
      // in-process path where capturedSamples grows the same way. The worker expects
      // full audio history for re-transcription. At 16kHz Float32, 2 min = ~7.7MB,
      // 5 min (max recording) = ~19MB. Bounded by TimingConstants.maxRecordingDuration.
      var nextIndex = 0
      var accumulated: [Float] = []
      await session.start(audioSamplesProvider: { @MainActor in
        let (newSamples, totalCount) = await capture.getSamplesSnapshot(fromIndex: nextIndex)
        accumulated.append(contentsOf: newSamples)
        nextIndex = totalCount
        return (samples: accumulated, count: accumulated.count)
      })
    } else {
      // In-process mode: read directly from MainActor-isolated capturedSamples.
      await session.start(audioSamplesProvider: { @MainActor in
        let samples = capture.capturedSamples
        return (samples: samples, count: samples.count)
      })
    }
  }

  // MARK: - VAD Monitoring

  private func startVADMonitoring() {
    vadMonitorTask = Task { [weak self] in
      await self?.monitorVAD()
    }
  }

  private func monitorVAD() async {
    // Detector setup stays in pipeline (owns silenceDetector lifecycle)
    let isXPCMode = audioCapture is AudioCaptureProxy
    var detector: SilenceDetector?

    if !isXPCMode {
      let config = SmoothedVADConfig.fromSensitivity(vadSensitivity, energyGate: vadEnergyGate)
      if silenceDetector == nil {
        silenceDetector = SilenceDetector(silenceTimeout: vadSilenceTimeout, vadConfig: config)
      }
      guard let det = silenceDetector else { return }
      await det.reset()
      await det.updateConfig(config)
      if !(await det.isReady) {
        do {
          try await det.prepare()
        } catch {
          Task {
            await AppLogger.shared.log(
              "VAD preparation failed: \(error)",
              level: .info, category: "VAD"
            )
          }
          return
        }
      }
      detector = det
    }

    let startTime = recordingStartTime ?? Date()
    let capture = audioCapture

    await VADMonitorLoop.run(
      detector: detector,
      vadAutoStop: vadAutoStop,
      maxDuration: TimingConstants.maxRecordingDuration,
      recordingStartTime: startTime,
      sampleProvider: { [weak capture] in capture?.capturedSamples ?? [] },
      isRecording: { [weak self] in self?.state == .recording && !(self?.isStopping ?? true) },
      onStop: { [weak self] _ in
        Task { [weak self] in await self?.stopAndTranscribe() }
      }
    )
  }

  // MARK: - Zombie engine telemetry (#302)

  /// Issue #302: zombie-engine zero-peak emission. Pre-checks the trigger
  /// shape (`peak == 0.0` with enough samples) here because the pipeline
  /// owns the sample buffer; the emitter handles dedup + payload shape.
  private func emitZombieEngineEventIfNeeded(rawSamples: [Float], peakAudioLevel: Float) {
    guard peakAudioLevel == 0.0,
      rawSamples.count >= AudioConstants.minimumTranscriptionSamples
    else { return }
    telemetry.zombieZeroPeak(
      ctx: ZeroPeakContext(
        sessionID: audioCapture.currentCaptureSessionID,
        durationMs: rawSamples.count * 1000 / 16_000,
        route: audioCapture.currentAudioRoute,
        sampleCount: rawSamples.count,
        isActivelyCapturing: audioCapture.isActivelyCapturing,
        captureSourceType: audioCapture.captureSourceType,
        inputDeviceUIDPreferred: audioCapture.preferredInputDeviceIDOverride.isEmpty
          ? nil : audioCapture.preferredInputDeviceIDOverride,
        inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID()
      )
    )
  }

  private func logLIDReleaseSignpost() {
    logLIDPerfSignpost(
      "t_release",
      timestamp: CFAbsoluteTimeGetCurrent(),
      sessionID: audioCapture.currentCaptureSessionID
    )
  }

  private func logLIDPerfSignpost(
    _ name: String,
    timestamp: CFAbsoluteTime,
    sessionID: UInt64,
    voicedDuration: TimeInterval? = nil,
    lidWindowCount: Int? = nil,
    clipKind: String? = nil
  ) {
    var fields = [
      "lid_perf_signpost",
      "name=\(name)",
      "timestamp_s=\(String(format: "%.6f", timestamp))",
      "session_id=\(sessionID)",
    ]
    if let voicedDuration {
      fields.append("voiced_duration_s=\(String(format: "%.3f", voicedDuration))")
    }
    if let lidWindowCount {
      fields.append("lid_window_count=\(lidWindowCount)")
    }
    if let clipKind {
      fields.append("clip_kind=\(clipKind)")
    }
    let message = fields.joined(separator: " ")
    Task {
      await AppLogger.shared.log(message, level: .info, category: "WhisperKitPipeline")
    }
  }

  // MARK: - Model Lifecycle

  private func scheduleModelUnloadIfNeeded() {
    modelUnloadTask?.cancel()
    modelUnloadTask = nil

    switch modelUnloadPolicy {
    case .never:
      return
    case .immediately:
      modelUnloadTask = Task { [weak self] in
        await self?.backend.unload()
      }
    default:
      guard let interval = modelUnloadPolicy.interval else { return }
      modelUnloadTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { return }
        await self?.backend.unload()
      }
    }
  }

  /// Fan out frozen config values to substeps and derive decode options.
  /// See `TranscriptionPipeline.applySessionConfig` for rationale.
  private func applySessionConfig(_ config: DictationSessionConfig) {
    llmPolishStep.llmProvider = config.llmProvider
    llmPolishStep.llmModel = config.llmModel
    llmPolishStep.polishInstructions = config.polishInstructions
    llmPolishStep.useExtendedThinking = config.useExtendedThinking

    // XPC audio service holds its own VAD state across the process boundary —
    // push the frozen values at recording start so the service-side
    // auto-stop behavior matches this recording's config.
    audioCapture.configureVAD(
      autoStop: config.vadAutoStop,
      silenceTimeout: config.vadSilenceTimeout,
      sensitivity: config.vadSensitivity,
      energyGate: config.vadEnergyGate
    )

    // Push the frozen device UIDs. See TranscriptionPipeline.applySessionConfig
    // for the narrow-race rationale.
    audioCapture.selectedInputDeviceUID = config.selectedInputDeviceUID
    audioCapture.preferredInputDeviceIDOverride = config.preferredInputDeviceIDOverride

    var opts = TranscriptionOptions()
    switch config.languageMode {
    case .auto:
      opts.language = nil
    case .locked(let code):
      opts.language = code
    }
    transcriptionOptions = opts
  }

  // MARK: - V2 fault-injection (DEBUG only, issue #291)

  #if DEBUG
    /// Invokes the existing `cancelRecording()` unwind path. Drives Lane A
    /// scenario A2 ("force-cancel mid-record") and Lane A scenario A8b
    /// ("cancel during WhisperKit model load") via the DEBUG localhost
    /// endpoint. Note that A8b validates state-unwind only — WhisperKit's
    /// `prepare()` is awaited directly with no held task, so the underlying
    /// load may still complete in the background after state has flipped.
    /// See `Tests/RuntimeUAT/SCENARIOS.md` for the documented limitation.
    ///
    /// `package` access: callable from `DebugFaultEndpoint` in the app target.
    /// Inert in release builds.
    package func forceCancelNow() async {
      await cancelRecording()
    }
  #endif

}
