import AppKit
import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

/// Orchestrates the full dictation pipeline: record → transcribe → (correct) → (polish) → store → copy/paste.
@MainActor
@Observable
public final class TranscriptionPipeline: DictationPipeline, HeartPathTelemetryTarget {
  private let audioCapture: any AudioCaptureInterface
  private let asrManager: any ASRManagerInterface
  private let transcriptStore: TranscriptStore
  private let keychainManager: KeychainManager

  public private(set) var state: PipelineState = .idle {
    didSet {
      if state != oldValue {
        onStateChange?(state)
      }
      // Honor the `currentSessionConfig` contract: nil when no recording is
      // in flight. Clear on every transition to a terminal state so callers
      // can distinguish an idle pipeline from one still mid-session.
      switch state {
      case .idle, .complete, .error:
        currentSessionConfig = nil
      case .loadingModel, .recording, .transcribing, .polishing:
        break
      }
    }
  }
  public var onStateChange: ((PipelineState) -> Void)?
  public private(set) var currentTranscript: Transcript?
  public var lastPolishError: String?

  /// Per-recording session config snapshot. Captured at `startRecording`; immutable
  /// for the duration of the recording. Settings mutated mid-recording apply to the
  /// NEXT recording. `nil` when no recording is in flight.
  public private(set) var currentSessionConfig: DictationSessionConfig?

  // MARK: - Session-scoped accessors (backed by `currentSessionConfig`)
  //
  // These reads are guaranteed to happen inside a recording's lifecycle
  // (from `startRecording` through `stopAndTranscribe`/`cancelRecording`),
  // so `currentSessionConfig` is set. The `??` fallbacks mirror the prior
  // public-property defaults and exist only as defense-in-depth.

  private var autoCopyToClipboard: Bool { currentSessionConfig?.autoCopyToClipboard ?? true }
  private var autoPasteToActiveApp: Bool { currentSessionConfig?.autoPasteToActiveApp ?? false }
  private var restoreClipboardAfterPaste: Bool {
    currentSessionConfig?.restoreClipboardAfterPaste ?? false
  }
  private var vadAutoStop: Bool { currentSessionConfig?.vadAutoStop ?? false }
  private var vadSilenceTimeout: Double { currentSessionConfig?.vadSilenceTimeout ?? 1.5 }
  private var vadSensitivity: Float { currentSessionConfig?.vadSensitivity ?? 0.5 }
  private var vadEnergyGate: Bool { currentSessionConfig?.vadEnergyGate ?? false }
  private var modelUnloadPolicy: ModelUnloadPolicy {
    currentSessionConfig?.modelUnloadPolicy ?? .never
  }

  /// Decode-time options. Mutable within a recording because LID results can
  /// overwrite `.language`. Re-derived from `config.languageMode` at each
  /// `startRecording`.
  private var transcriptionOptions: TranscriptionOptions = .default

  // Shared services
  private let transcriptFinalizer: TranscriptFinalizer

  /// App-wide capture telemetry state (shared with WhisperKit pipeline).
  /// Owns dedupe for zombie-engine events (#302) and the
  /// AVAudioEngineConfigurationChange counter (#294 smoking-gun diagnostic).
  private let captureTelemetry: CaptureTelemetryState

  // Text processing steps
  private let wordCorrectionStep = WordCorrectionStep()
  private let fillerRemovalStep = FillerRemovalStep()
  private let llmPolishStep: LLMPolishStep
  private var textProcessingSteps: [any TextProcessingStep] = []

  /// Access word correction step for configuration.
  public var wordCorrection: WordCorrectionStep { wordCorrectionStep }
  /// Access filler removal step for configuration.
  public var fillerRemoval: FillerRemovalStep { fillerRemovalStep }
  /// Access LLM polish step for configuration.
  public var llmPolish: LLMPolishStep { llmPolishStep }

  /// The app that was frontmost when recording started — re-activated before pasting.
  private var targetApp: NSRunningApplication?
  /// The specific text field that was focused when recording started — used for AX direct insertion.
  private var targetElement: AXUIElement?
  private var silenceDetector: SilenceDetector?
  private var vadMonitorTask: Task<Void, Never>?
  private var recordingStartTime: Date?
  /// User preference: use streaming ASR during recording (lower latency) or batch after stop (cleaner text).
  /// Frozen per recording in `currentSessionConfig`.
  private var useStreamingASR: Bool { currentSessionConfig?.useStreamingASR ?? true }
  /// Whether streaming ASR was successfully started for the current recording.
  private var streamingASRActive = false
  /// Counters for diagnosing streaming buffer delivery (tail-cutoff instrumentation).
  private var streamingBuffersDispatched = 0
  private var streamingBuffersFed = 0
  /// Guards against concurrent stopAndTranscribe calls (e.g., VAD auto-stop racing PTT release).
  private var isStopping = false
  /// Guards against concurrent startRecording calls (e.g., rapid toggle presses).
  private var isStarting = false
  /// Set by key-up when startRecording() is still in-flight; checked after .recording is entered.
  private var stopRequested = false
  /// Whether audio input has been pre-warmed (engine started) by PTT key-down.
  private var isPreWarmed = false
  /// Frozen snapshot of recording state, built before teardown for post-recording error enrichment.
  private var frozenSnapshot: SentryBreadcrumb.RecordingSnapshot?
  /// Cancellable model load task. Cancelled by cancelRecording() during .loadingModel.
  /// Late completion after cancel is guarded by checking state == .loadingModel before proceeding.
  private var modelLoadTask: Task<Void, any Error>?

  // Issue #285 — stall vs final no-audio dedup. One Sentry event per wedge
  // incident even though the stall watchdog and the `rawSamples.isEmpty`
  // branch both observe the same session. Reset on session-id change.
  private var stallEventAlreadyCaptured: Bool = false
  private var lastObservedCaptureSession: UInt64 = 0
  /// Set when the proxy's reply-path swallowed an XPC failure. The
  /// rawSamples-empty branch dedups against this so we emit `xpc_service_error`
  /// instead of also firing `no_audio_captured` for the same incident.
  private var xpcReplyFailedThisSession: Bool = false

  /// Issue #289 stall-recovery ownership token. Set to the stalled session's
  /// ID when `handleCaptureStall` flips state to `.error`, cleared by any path
  /// that takes ownership back (fresh `startRecording`, `cancelRecording`,
  /// `reset`, engine interruption). `finishStallRecovery` bails unless the
  /// token still matches, so a fast retry that hasn't yet reached
  /// `beginCapturePhase()` (and therefore hasn't advanced
  /// `currentCaptureSessionID`) is not torn down by stale cleanup.
  private var pendingStallRecoveryToken: UInt64?

  public init(
    audioCapture: any AudioCaptureInterface,
    asrManager: any ASRManagerInterface,
    transcriptStore: TranscriptStore,
    keychainManager: KeychainManager = KeychainManager(),
    captureTelemetry: CaptureTelemetryState = CaptureTelemetryState()
  ) {
    self.audioCapture = audioCapture
    self.asrManager = asrManager
    self.transcriptStore = transcriptStore
    self.keychainManager = keychainManager
    self.captureTelemetry = captureTelemetry
    self.transcriptFinalizer = TranscriptFinalizer(transcriptStore: transcriptStore)
    self.llmPolishStep = LLMPolishStep(keychainManager: keychainManager)
    // Explicit engine identity: makes the Parakeet path non-inferred. The
    // planner will force the legacy English-centric path for Parakeet
    // regardless of any `languageDetection` a caller might set.
    llmPolishStep.backend = .parakeet
    llmPolishStep.onWillProcess = { [weak self] in
      self?.state = .polishing
    }

    // Engine interruption cleanup is wired by AppState.onEngineInterrupted
    // (unified handler that routes to the active pipeline). The pipeline exposes
    // handleEngineInterruption() for AppState to call.
    // Activate SSE streaming for Gemini — a non-nil onToken causes GeminiConnector
    // to use streamGenerateContent instead of batch generateContent.
    // No-op callback is correct; live token display in overlay is a future follow-up.
    llmPolishStep.onToken = { _ in }
    textProcessingSteps = [wordCorrectionStep, fillerRemovalStep, llmPolishStep]

    // Issue #285 — telemetry callbacks on `audioCapture` are single-owner
    // properties and both pipelines share the same instance. `AppState`
    // centralizes routing to the active pipeline (same pattern as
    // `onEngineInterrupted`) and calls into our public `handleCaptureStall` /
    // `handleXPCReplyFailed` / `handleCaptureSessionInterruption` methods.
  }

  public func handleCaptureSessionInterruption(_ ctx: CaptureSessionInterruptionContext) {
    SentryBreadcrumb.captureError(
      HeartPathError.captureSessionInterrupted(ctx: ctx),
      category: .audioCaptureFailed,
      stage: "audio",
      extra: [
        "capture_session.kind": ctx.kind.rawValue,
        "capture_session.reason_code": ctx.reasonCode.map { $0 } ?? NSNull(),
        "capture_session.reason_label": ctx.reasonLabel ?? NSNull(),
        "capture_session.error_domain": ctx.errorDomain ?? NSNull(),
        "capture_session.error_code": ctx.errorCode.map { $0 } ?? NSNull(),
        "capture_session.error_description": ctx.errorDescription ?? NSNull(),
        "capture.is_actively_capturing": ctx.isActivelyCapturing,
        "capture_session_id": Int(ctx.sessionID),
      ]
    )
  }

  public func handleXPCReplyFailed(_ ctx: XPCReplyFailureContext) {
    resetStallFlagIfNewSession(ctx.sessionID)
    xpcReplyFailedThisSession = true
    SentryBreadcrumb.captureError(
      HeartPathError.xpcReplyFailed(ctx: ctx),
      category: .xpcServiceError,
      stage: "audio",
      extra: [
        "xpc.reply_stage": ctx.replyStage,
        "xpc.error_domain": ctx.errorDomain,
        "xpc.error_code": ctx.errorCode,
        "capture_session_id": Int(ctx.sessionID),
      ]
    )
  }

  public func handleCaptureStall(_ ctx: CaptureStallContext) {
    resetStallFlagIfNewSession(ctx.sessionID)
    guard !stallEventAlreadyCaptured else { return }
    stallEventAlreadyCaptured = true
    let extras = SentryAudioExtras.buildCaptureExtras(
      route: ctx.route,
      sourceType: ctx.sourceType,
      sessionID: ctx.sessionID,
      isActivelyCapturing: audioCapture.isActivelyCapturing,
      inputDeviceUIDPreferred: ctx.inputDeviceUIDPreferred,
      inputDeviceUIDSystemDefault: ctx.inputDeviceUIDSystemDefault,
      failureMode: "stall_window_elapsed",
      stallContext: ctx
    )
    SentryBreadcrumb.captureError(
      HeartPathError.audioCaptureStalled(sessionID: ctx.sessionID, ctx: ctx),
      category: .audioCaptureStalled,
      stage: "recording",
      extra: extras
    )

    // Issue #289: flip terminal state SYNCHRONOUSLY before any await so a
    // racing PTT key-up can't slip into `stopAndTranscribe` against a live
    // `.recording` state. `stallEventAlreadyCaptured` already dedups re-entry.
    guard state == .recording else { return }
    stopRequested = true
    isPreWarmed = false
    recordingStartTime = nil
    pendingStallRecoveryToken = ctx.sessionID
    state = .error("No audio detected — try again.")

    // Async cleanup — token-gated. `currentCaptureSessionID` alone is
    // insufficient because `preWarm()` / `startEnginePhase()` do not advance
    // it (Codex 2026-04-15); a fast retry would slip through a sessionID-only
    // gate while still pre-`beginCapturePhase`. The token is cleared by any
    // path that takes ownership back, so fast-retry + cross-pipeline races
    // both bail cleanly here.
    Task { @MainActor [weak self, sessionID = ctx.sessionID] in
      await self?.finishStallRecovery(for: sessionID)
    }
  }

  /// Issue #289: token-gated cleanup after `handleCaptureStall` flipped
  /// terminal state. Bails if any path has taken ownership back.
  /// `stopCapture()` is required — the source-side watchdog is only cancelled
  /// by stop / deactivate / interruption paths, so a state-only recovery
  /// would leak it in the committed-recovery case.
  @MainActor
  private func finishStallRecovery(for sessionID: UInt64) async {
    // Defense-in-depth: if state has moved off `.error` since we scheduled
    // cleanup, another path is in-flight (retry, cancel, interruption) —
    // do not stopCapture.
    guard case .error = state else { return }
    guard pendingStallRecoveryToken == sessionID else { return }
    guard audioCapture.currentCaptureSessionID == sessionID else { return }
    pendingStallRecoveryToken = nil
    vadMonitorTask?.cancel()
    vadMonitorTask = nil
    if streamingASRActive {
      await asrManager.cancelStreaming()
    }
    deactivateStreamingForwarding()
    _ = await audioCapture.stopCapture()
  }

  private func resetStallFlagIfNewSession(_ sessionID: UInt64) {
    guard sessionID != lastObservedCaptureSession else { return }
    lastObservedCaptureSession = sessionID
    stallEventAlreadyCaptured = false
    xpcReplyFailedThisSession = false
  }

  /// Emit either a dedup breadcrumb (stall already fired for this session) or a
  /// terminal `audioCaptureFailed` captureError. Called from the rawSamples-empty
  /// branch after stopCapture.
  private func emitNoAudioCapturedEvent(wasStreaming: Bool) {
    let sessionID = audioCapture.currentCaptureSessionID
    resetStallFlagIfNewSession(sessionID)
    let durationMs: Int = {
      guard let start = recordingStartTime else { return 0 }
      return Int(Date().timeIntervalSince(start) * 1000)
    }()
    let route = audioCapture.currentAudioRoute
    if stallEventAlreadyCaptured || xpcReplyFailedThisSession {
      let dedupedFrom =
        stallEventAlreadyCaptured ? "audio_capture_stalled" : "xpc_reply_failed"
      SentryBreadcrumb.add(
        stage: "recording",
        message: "No audio captured (deduped)",
        level: .warning,
        data: [
          "deduped_from": dedupedFrom,
          "capture_session_id": Int(sessionID),
        ]
      )
      return
    }
    let err = HeartPathError.noAudioCaptured(
      sessionID: sessionID,
      durationMs: durationMs,
      wasStreaming: wasStreaming,
      route: route
    )
    SentryBreadcrumb.captureError(
      err,
      category: .audioCaptureFailed,
      stage: "recording",
      extra: SentryAudioExtras.buildCaptureExtras(
        route: route,
        sourceType: audioCapture.captureSourceType,
        sessionID: sessionID,
        isActivelyCapturing: audioCapture.isActivelyCapturing,
        inputDeviceUIDPreferred: audioCapture.preferredInputDeviceIDOverride.isEmpty
          ? nil : audioCapture.preferredInputDeviceIDOverride,
        inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID(),
        failureMode: "no_audio_captured"
      )
    )
  }

  /// Pre-warm the audio input to trigger any Bluetooth codec switch before recording.
  /// Called on PTT key-down to hide the 0.5-2s Bluetooth negotiation latency.
  /// Sets `isPreWarmed` so `startRecording()` skips engine phase 1.
  public func preWarmAudioInput() async throws {
    guard !state.isActive, state != .recording else { return }
    // Issue #289: earliest new-attempt signal — clear any stale stall-recovery
    // token BEFORE the cleanup Task can race against this retry's `preWarm`
    // and `startEnginePhase`, neither of which advance currentCaptureSessionID.
    // Clearing in `startRecording` alone was too late: the async cleanup could
    // fire during the window between `preWarmAudioInput` start and
    // `startRecording` entry (PTT event flow is `.preWarm` then
    // `.toggleRecording`). Same-pipeline retry only; cross-pipeline backend
    // switch is a narrower window handled by the sessionID gate once
    // `beginCapturePhase()` runs on the other pipeline.
    pendingStallRecoveryToken = nil
    stopRequested = false
    let start = ContinuousClock.now
    // Issue #289: propagate preWarm failures. `isPreWarmed` is only flipped
    // to true on a real success — never against a dead capture path.
    try await audioCapture.preWarm()
    guard !Task.isCancelled else { return }
    isPreWarmed = true
    let totalMs = PipelineUtils.durationMs(ContinuousClock.now - start)
    Task {
      await AppLogger.shared.log(
        "COLD-START [Parakeet] preWarmAudioInput total=\(totalMs)ms",
        level: .info, category: "Pipeline"
      )
    }
  }

  /// Toggle recording: start if idle, stop if recording. On start transitions,
  /// the provided session config is captured; on stop transitions the config
  /// is ignored (the in-flight recording continues to use its original snapshot).
  public func toggleRecording(config: DictationSessionConfig) async {
    switch state {
    case .idle, .complete, .error:
      await startRecording(config: config)
    case .recording:
      await stopAndTranscribe()
    case .loadingModel, .transcribing, .polishing:
      break  // Don't interrupt processing
    }
  }

  /// Start recording audio from the microphone. `config` freezes per-recording
  /// settings (auto-paste, VAD config, polish provider/model, etc.) for the
  /// duration of this recording. Mid-recording setting changes apply to the
  /// NEXT recording's snapshot.
  public func startRecording(config: DictationSessionConfig) async {
    currentSessionConfig = config
    applySessionConfig(config)
    // Issue #289: new attempt takes ownership — any pending stall recovery
    // from a prior session must not tear down the fresh source.
    pendingStallRecoveryToken = nil
    guard !Task.isCancelled else { return }
    guard !isStarting else { return }
    guard !state.isActive || state == .complete else { return }
    isStarting = true
    defer { isStarting = false }

    lastPolishError = nil
    deactivateStreamingForwarding()

    // Cancel idle timer so model stays loaded during recording.
    asrManager.cancelIdleTimer()

    // Ensure model is loaded (model should already be warm from launch-time preload).
    // Wrap in a cancellable task so cancelRecording() can abort a cold-start load.
    if !asrManager.isModelLoaded {
      state = .loadingModel
      SentryBreadcrumb.add(
        stage: "asr", message: "Model loading",
        data: ["backend": asrManager.activeBackendType.rawValue])
      let loadTask = Task {
        try await asrManager.loadModel()
      }
      modelLoadTask = loadTask
      do {
        try await loadTask.value
      } catch is CancellationError {
        // User cancelled during model load. Return to idle.
        stopRequested = false
        modelLoadTask = nil
        state = .idle
        return
      } catch {
        SentryBreadcrumb.captureError(
          error, category: .modelLoadFailed, stage: "asr",
          extra: ["backend": asrManager.activeBackendType.rawValue])
        stopRequested = false
        modelLoadTask = nil
        state = .error("Model load failed: \(error.localizedDescription)")
        return
      }
      modelLoadTask = nil
      // Late-completion guard: if state changed while we were loading (e.g., cancel),
      // do not proceed. The cancel handler already set state to .idle.
      guard state == .loadingModel else { return }
      guard !Task.isCancelled else { return }
    }

    // Remember the frontmost app and focused text field so we can paste back
    // (LLM polishing can take seconds, during which focus may shift)
    targetApp = NSWorkspace.shared.frontmostApplication
    targetElement = PasteService.captureFocusedElement()

    // BRAIN: gotcha id=pipeline-timing-misconception
    // Start streaming ASR if the backend supports it — feed audio buffers
    // to the ASR model during recording so transcription overlaps with capture.
    var streamingSetupSucceeded = false
    defer { if !streamingSetupSucceeded { deactivateStreamingForwarding() } }

    let supportsStreaming = await asrManager.activeBackendSupportsStreaming
    if supportsStreaming && useStreamingASR {
      do {
        try await asrManager.startStreaming(options: transcriptionOptions)
        streamingASRActive = true
        streamingBuffersDispatched = 0
        streamingBuffersFed = 0
        SentryBreadcrumb.add(
          stage: "asr", message: "Streaming ASR started",
          data: ["backend": asrManager.activeBackendType.rawValue])

        // Wire audio buffer forwarding: each converted buffer goes to streaming ASR.
        // The streamingASRActive flag gates delivery — deactivateStreamingForwarding()
        // sets it to false and nils onBufferCaptured, so in-flight tasks exit quickly.
        //
        // NOTE: This callback runs on the real-time audio thread. The TapStoppedFlag
        // in AudioCaptureManager prevents this from being called after teardown starts.
        // The nonisolated(unsafe) is safe because the buffer is created on the audio
        // thread, transferred to the main thread via Task, and never accessed from
        // both threads simultaneously.
        audioCapture.onBufferCaptured = { [weak self] buffer in
          guard let self else { return }
          nonisolated(unsafe) let safeBuffer = buffer
          Task { @MainActor in
            self.streamingBuffersDispatched += 1
            guard self.streamingASRActive, self.state == .recording else { return }
            try? await self.asrManager.feedAudio(safeBuffer)
            self.streamingBuffersFed += 1
          }
        }

        Task {
          await AppLogger.shared.log(
            "Streaming ASR started during recording",
            level: .info, category: "Pipeline"
          )
        }
      } catch {
        // Streaming init failed — fall back to batch after recording
        deactivateStreamingForwarding()
        SentryBreadcrumb.add(
          stage: "asr", message: "Streaming start failed, will use batch", level: .warning)
        Task {
          await AppLogger.shared.log(
            "Streaming ASR failed to start, will use batch: \(error.localizedDescription)",
            level: .info, category: "Pipeline"
          )
        }
      }
    }

    do {
      // Two-phase start: phase 1 triggers any Bluetooth codec switch
      if !isPreWarmed {
        try await audioCapture.startEnginePhase()

        // Wait for format to stabilize (Bluetooth) or pass immediately (built-in mic)
        let stabilized = await audioCapture.waitForFormatStabilization(
          maxWait: 1.5,
          pollInterval: 0.2
        )
        guard !Task.isCancelled else {
          isPreWarmed = false
          return
        }

        // If format never settled, rebuild engine once and retry
        if !stabilized {
          audioCapture.rebuildEngine()
          try await audioCapture.startEnginePhase()
        }
      }
      isPreWarmed = false

      // Phase 2: install tap and start capture
      _ = try await audioCapture.beginCapturePhase()
      streamingSetupSucceeded = true
      state = .recording
      recordingStartTime = Date()
      currentTranscript = nil
      SentryBreadcrumb.add(
        stage: "recording", message: "Recording started",
        data: [
          "backend": asrManager.activeBackendType.rawValue,
          "streaming": streamingASRActive,
        ])
      SentryBreadcrumb.updateRecordingState(
        active: true, backend: "parakeet", isStreaming: streamingASRActive)
      SentryBreadcrumb.updateAudioRoute(audioCapture.currentAudioRoute)

      if stopRequested {
        stopRequested = false
        await stopAndTranscribe()
        return
      }

      Task {
        await AppLogger.shared.log(
          "Recording started. Backend: \(asrManager.activeBackendType.rawValue), streaming=\(streamingASRActive)",
          level: .info, category: "Pipeline"
        )
      }

      // Always start VAD monitoring for silence removal
      startVADMonitoring()
    } catch {
      // startCapture() failed — cancel any streaming session we started
      if streamingASRActive {
        await asrManager.cancelStreaming()
      }
      deactivateStreamingForwarding()
      SentryBreadcrumb.captureError(
        error,
        category: .audioCaptureFailed,
        stage: "recording",
        extra: SentryAudioExtras.buildCaptureExtras(
          route: audioCapture.currentAudioRoute,
          sourceType: audioCapture.captureSourceType,
          sessionID: audioCapture.currentCaptureSessionID,
          isActivelyCapturing: audioCapture.isActivelyCapturing,
          inputDeviceUIDPreferred: audioCapture.preferredInputDeviceIDOverride.isEmpty
            ? nil : audioCapture.preferredInputDeviceIDOverride,
          inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID(),
          failureMode: "thrown_start"
        )
      )
      stopRequested = false
      state = .error("Recording failed: \(error.localizedDescription)")
    }
  }

  /// Stop recording, or set a flag if startRecording() is still in-flight.
  /// Handles the pre-warm phase (.idle) as well as model loading (.transcribing).
  public func requestStop() async {
    switch state {
    case .recording:
      await stopAndTranscribe()
    case .idle, .loadingModel, .transcribing:
      // .idle: startRecording is in-flight (pre-warm/engine setup) → will check after entering .recording.
      // .loadingModel/.transcribing: model load or ASR in progress → startRecording will check and stop.
      stopRequested = true
      // PTT release before recording started — clean up pre-warmed audio engine
      if state == .idle, isPreWarmed {
        isPreWarmed = false
        audioCapture.abortPreWarm()
      }
    case .polishing, .complete, .error:
      // Pipeline is past the point of no return or already finished — ignore.
      break
    }
  }

  /// Stop recording and transcribe the captured audio.
  public func stopAndTranscribe() async {
    guard state == .recording, !isStopping else { return }
    isStopping = true
    defer { isStopping = false }

    let pipelineStart = CFAbsoluteTimeGetCurrent()

    // Silently discard recordings shorter than minimum duration (accidental taps)
    if let startTime = recordingStartTime {
      let elapsed = Date().timeIntervalSince(startTime)
      if elapsed < TimingConstants.minimumRecordingDuration {
        vadMonitorTask?.cancel()
        vadMonitorTask = nil
        if streamingASRActive {
          await asrManager.cancelStreaming()
        }
        deactivateStreamingForwarding()
        _ = await audioCapture.stopCapture()
        recordingStartTime = nil
        state = .idle
        Task {
          await AppLogger.shared.log(
            "Recording too short (\(String(format: "%.2f", elapsed))s), discarded silently",
            level: .info, category: "Pipeline"
          )
        }
        return
      }
    }
    // Freeze snapshot BEFORE teardown — post-recording errors use this instead of live scope.
    let snapshotStartTime = recordingStartTime ?? Date()
    let durationMs = Int(Date().timeIntervalSince(snapshotStartTime) * 1000)
    frozenSnapshot = SentryBreadcrumb.RecordingSnapshot(
      backend: "parakeet",
      audioRoute: audioCapture.currentAudioRoute,
      wasStreaming: streamingASRActive,
      startTime: snapshotStartTime,
      durationMs: durationMs,
      targetAppBundleID: targetApp?.bundleIdentifier
    )

    recordingStartTime = nil

    // Cancel VAD monitoring
    vadMonitorTask?.cancel()
    vadMonitorTask = nil

    let wasStreaming = streamingASRActive

    // Stop the audio tap FIRST — prevents new buffer-feed tasks from being dispatched.
    // Then yield to drain any in-flight feed tasks already queued on @MainActor.
    // These tasks check streamingASRActive (still true) and deliver their buffers
    // to the Parakeet actor before we deactivate forwarding.
    // Without this reorder, deactivateStreamingForwarding() sets the flag to false
    // and all queued tasks drop their buffers — losing ~250-500ms of trailing audio.
    let captureResult = await audioCapture.stopCapture()
    let rawSamples = captureResult.samples
    SentryBreadcrumb.add(
      stage: "recording", message: "Recording stopped", data: ["sample_count": rawSamples.count])
    SentryBreadcrumb.updateRecordingState(active: false)

    if wasStreaming {
      // Deterministic drain: freeze the dispatch count after stopCapture (no new buffers
      // will be dispatched since the tap/session is stopped). Wait for all queued buffer-feed
      // tasks to complete before deactivating forwarding. Bounded by 500ms deadline.
      let targetDispatched = streamingBuffersDispatched
      let drainDeadline = ContinuousClock.now + .milliseconds(500)
      while streamingBuffersFed < targetDispatched,
        ContinuousClock.now < drainDeadline
      {
        await Task.yield()
      }
      if streamingBuffersFed >= targetDispatched {
        Task {
          await AppLogger.shared.log(
            "Streaming drain: clean (\(self.streamingBuffersFed)/\(targetDispatched) fed)",
            level: .info, category: "PipelineTiming"
          )
        }
      } else {
        Task {
          await AppLogger.shared.log(
            "Streaming drain: TIMEOUT (\(self.streamingBuffersFed)/\(targetDispatched) fed — \(targetDispatched - self.streamingBuffersFed) lost)",
            level: .info, category: "PipelineTiming"
          )
        }
      }
    }

    deactivateStreamingForwarding()

    // Defense: if cancelRecording() ran during yield, bail out
    guard state == .recording else { return }

    // Pre-warm the LLM backend while ASR is still running (fire-and-forget).
    LLMNetworkSession.shared.preWarmModel(
      provider: llmPolishStep.llmProvider,
      model: llmPolishStep.llmModel,
      keychainManager: keychainManager
    )

    guard !rawSamples.isEmpty else {
      // Cancel streaming if it was active — empty samples means no useful audio
      if wasStreaming {
        await asrManager.cancelStreaming()
      }
      emitNoAudioCapturedEvent(wasStreaming: wasStreaming)
      state = .error("No audio captured")
      return
    }

    Task {
      await AppLogger.shared.log(
        "Captured \(rawSamples.count) samples (\(String(format: "%.2f", Double(rawSamples.count)/16000))s)",
        level: .verbose, category: "Pipeline"
      )
    }

    // Filter silence using VAD speech segments (used for batch fallback and logging).
    var samples: [Float]
    var hasSpeechEvidence = false
    var vadSegmentCount = 0
    var vadSpeechDurationMs = 0
    let isXPCMode = audioCapture is AudioCaptureProxy
    if isXPCMode {
      // XPC mode: VAD segments are returned atomically with samples from stopCapture().
      // This eliminates the call-order bug where separate getVADSegments() read
      // capturedSamples.count as 0 after stopCapture() cleared the buffer (#226).
      let segments = captureResult.vadSegments
      hasSpeechEvidence = !segments.isEmpty
      vadSegmentCount = segments.count
      vadSpeechDurationMs =
        segments.reduce(0) { $0 + ($1.endSample - $1.startSample) } * 1000 / 16000
      if !segments.isEmpty {
        samples = SampleFilter.filter(from: rawSamples, segments: segments)
      } else {
        samples = rawSamples
      }
    } else if let detector = silenceDetector {
      await detector.finalizeSegments(totalSampleCount: rawSamples.count)
      let segments = await detector.speechSegments
      hasSpeechEvidence = !segments.isEmpty
      vadSegmentCount = segments.count
      vadSpeechDurationMs =
        segments.reduce(0) { $0 + ($1.endSample - $1.startSample) } * 1000 / 16000
      samples = await detector.filterSamples(from: rawSamples)
    } else {
      samples = rawSamples
      // No VAD detector available -- cannot determine speech presence.
      // Default to true so that empty ASR results still fire Sentry errors
      // (fail toward visibility rather than silently swallowing failures).
      hasSpeechEvidence = true
    }
    let peakAudioLevel = rawSamples.reduce(Float(0)) { max($0, abs($1)) }

    Task {
      await AppLogger.shared.log(
        "VAD filtered to \(samples.count) samples (\(String(format: "%.1f", Double(samples.count)/Double(max(rawSamples.count, 1))*100))% voiced)",
        level: .verbose, category: "Pipeline"
      )
    }

    // VAD gate: if no speech was detected, skip ASR entirely.
    // Prevents noise-induced hallucinations ("Okay", "Yeah") from ambient sounds.
    // The decoder hallucinates filler words from low-information audio; not
    // invoking it eliminates the problem at the source.
    if !hasSpeechEvidence {
      if wasStreaming {
        await asrManager.cancelStreaming()
      }
      SentryBreadcrumb.add(
        stage: "asr", message: "VAD gate: no speech detected, skipping ASR",
        level: .info,
        data: [
          "backend": asrManager.activeBackendType.rawValue,
          "mode": wasStreaming ? "streaming" : "batch",
          "raw_sample_count": rawSamples.count,
          "peak_audio_level": peakAudioLevel,
        ]
      )
      emitZombieEngineEventIfNeeded(rawSamples: rawSamples, peakAudioLevel: peakAudioLevel)
      frozenSnapshot = nil
      state = .idle
      Task {
        await AppLogger.shared.log(
          "VAD gate: no speech, skipping ASR (samples=\(rawSamples.count), peak=\(String(format: "%.4f", peakAudioLevel)))",
          level: .info, category: "Pipeline"
        )
      }
      return
    }

    // ASR backends require >= 1 second of audio.
    // If VAD filtering was too aggressive, fall back to raw samples.
    let minimumSamples = AudioConstants.minimumTranscriptionSamples
    if samples.count < minimumSamples && rawSamples.count >= minimumSamples {
      samples = rawSamples
    }

    // Pad short recordings with silence so single-word inputs ("hey", "hi") work.
    if samples.count > 0 && samples.count < minimumSamples {
      samples.append(contentsOf: [Float](repeating: 0, count: minimumSamples - samples.count))
    }

    state = .transcribing
    SentryBreadcrumb.add(
      stage: "asr", message: "Transcription started",
      data: [
        "mode": wasStreaming ? "streaming" : "batch",
        "backend": asrManager.activeBackendType.rawValue,
      ])

    do {
      let asrStart = CFAbsoluteTimeGetCurrent()

      // Use streaming finalize when available for lowest latency.
      // FluidAudio fork uses fresh decoder state per chunk + chunk-aware text assembly
      // to eliminate the ~12% text loss that affected upstream SlidingWindowAsrManager.
      // Streaming mode includes batch rescue: if finalize fails or returns empty
      // despite VAD speech evidence, retry with batch decode using captured samples.
      let result: ASRResult
      if wasStreaming {
        result = try await transcribeWithStreamingRescue(
          samples: samples,
          hasSpeechEvidence: hasSpeechEvidence
        )
      } else {
        result = try await asrManager.transcribe(
          audioSamples: samples, options: transcriptionOptions)
      }

      let asrEnd = CFAbsoluteTimeGetCurrent()

      let asrText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !asrText.isEmpty else {
        if hasSpeechEvidence {
          // Real ASR failure: VAD detected speech but decoder returned nothing
          SentryBreadcrumb.captureError(
            NSError(
              domain: "EnviousWispr", code: -1,
              userInfo: [
                NSLocalizedDescriptionKey: "ASR returned empty text despite speech evidence"
              ]),
            category: .asrEmptyResult, stage: "asr",
            extra: [
              "backend": asrManager.activeBackendType.rawValue,
              "mode": wasStreaming ? "streaming" : "batch",
              "has_speech_evidence": true,
              "raw_sample_count": rawSamples.count,
              "vad_segment_count": vadSegmentCount,
              "vad_speech_duration_ms": vadSpeechDurationMs,
              "peak_audio_level": peakAudioLevel,
            ],
            snapshot: frozenSnapshot
          )
          state = .error("Couldn't catch that -- try again")
          Task {
            await AppLogger.shared.log(
              "ASR empty despite speech evidence (segments=\(vadSegmentCount), speechMs=\(vadSpeechDurationMs), peak=\(peakAudioLevel))",
              level: .info, category: "Pipeline"
            )
          }
        } else {
          // Expected: user held button without speaking
          SentryBreadcrumb.add(
            stage: "asr", message: "ASR empty (no speech detected)",
            level: .info,
            data: [
              "backend": asrManager.activeBackendType.rawValue,
              "mode": wasStreaming ? "streaming" : "batch",
            ]
          )
          state = .idle
          Task {
            await AppLogger.shared.log(
              "No speech detected, returning to idle",
              level: .info, category: "Pipeline"
            )
          }
        }
        frozenSnapshot = nil
        return
      }

      SentryBreadcrumb.add(
        stage: "asr", message: "ASR completed",
        data: [
          "mode": wasStreaming ? "streaming" : "batch",
          "backend": asrManager.activeBackendType.rawValue,
          "duration_s": String(format: "%.3f", asrEnd - asrStart),
          "char_count": asrText.count,
        ])
      Task {
        await AppLogger.shared.log(
          "Pipeline timing: ASR completed in \(String(format: "%.3f", asrEnd - asrStart))s "
            + "(mode=\(wasStreaming ? "streaming" : "batch"), \(asrText.count) chars, lang=\(result.language ?? "?"))",
          level: .info, category: "PipelineTiming"
        )
      }

      // Post-ASR finalization: text processing -> store -> paste
      let finalizationResult: FinalizationResult
      do {
        finalizationResult = try await transcriptFinalizer.finalize(
          FinalizationRequest(
            asrText: asrText,
            language: result.language,
            duration: result.duration,
            processingTime: result.processingTime,
            backendType: result.backendType,
            targetApp: targetApp,
            targetElement: targetElement,
            autoCopyToClipboard: autoCopyToClipboard,
            autoPasteToActiveApp: autoPasteToActiveApp,
            restoreClipboardAfterPaste: restoreClipboardAfterPaste,
            steps: textProcessingSteps
          ))
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
              "backend": "parakeet",
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

      // Notify ASR manager that transcription is done; schedules unload timer if configured.
      asrManager.noteTranscriptionComplete(policy: modelUnloadPolicy)

      // Build metrics (pipeline-specific: uses ASR timing, streaming mode)
      let pasteTargetApp = targetApp?.bundleIdentifier
      targetApp = nil
      targetElement = nil

      let pipelineEnd = CFAbsoluteTimeGetCurrent()
      let polishDuration = finalizationResult.polishDurationSeconds
      let pasteDuration = finalizationResult.pasteDurationSeconds
      Task {
        await AppLogger.shared.log(
          "Pipeline timing TOTAL: \(String(format: "%.3f", pipelineEnd - pipelineStart))s "
            + "(ASR=\(String(format: "%.3f", asrEnd - asrStart))s, "
            + "polish=\(String(format: "%.3f", polishDuration))s, "
            + "paste=\(String(format: "%.3f", pasteDuration))s)",
          level: .info, category: "PipelineTiming"
        )
      }

      var transcript = finalizationResult.transcript
      transcript.metrics = ExecutionMetrics(
        asrLatencySeconds: asrEnd - asrStart,
        llmLatencySeconds: polishDuration,
        pasteTier: finalizationResult.pasteResult?.tier.rawValue,
        pasteLatencyMs: finalizationResult.pasteResult?.durationMs,
        targetApp: pasteTargetApp,
        coldStart: false,
        streamingMode: wasStreaming,
        e2eSeconds: pipelineEnd - pipelineStart
      )
      currentTranscript = transcript
      SentryBreadcrumb.add(
        stage: "pipeline", message: "Pipeline complete",
        data: [
          "e2e_s": String(format: "%.3f", pipelineEnd - pipelineStart),
          "asr_s": String(format: "%.3f", asrEnd - asrStart),
          "polish_s": String(format: "%.3f", polishDuration),
          "paste_tier": finalizationResult.pasteResult?.tier.rawValue ?? "none",
          "backend": asrManager.activeBackendType.rawValue,
        ])
      captureTelemetry.recordSuccessfulRecording()
      frozenSnapshot = nil
      state = .complete
    } catch {
      SentryBreadcrumb.captureError(
        error, category: .asrFailed, stage: "transcription",
        extra: [
          "backend": asrManager.activeBackendType.rawValue
        ], snapshot: frozenSnapshot)
      frozenSnapshot = nil
      state = .error("Transcription failed: \(error.localizedDescription)")
    }
  }

  /// Issue #302: emit a Sentry event when the VAD gate gets a full recording's
  /// worth of exactly-zero audio. That signature (`peak == 0.0` with non-empty
  /// samples) matches the zombie-engine failure described in gotchas.md, not
  /// genuine silence (which has a noise floor). Dedupes via captureTelemetry.
  private func emitZombieEngineEventIfNeeded(rawSamples: [Float], peakAudioLevel: Float) {
    guard peakAudioLevel == 0.0,
      rawSamples.count >= AudioConstants.minimumTranscriptionSamples
    else { return }

    let route = audioCapture.currentAudioRoute
    let sessionID = audioCapture.currentCaptureSessionID
    let durationMs = rawSamples.count * 1000 / 16_000
    let shouldEmit = captureTelemetry.shouldEmitZombie(
      route: route, window: .seconds(30))
    captureTelemetry.markZombieEmitted(route: route)

    guard shouldEmit else { return }

    let err = HeartPathError.zombieEngineZeroPeak(
      sessionID: sessionID,
      durationMs: durationMs,
      route: route,
      sampleCount: rawSamples.count
    )
    SentryBreadcrumb.captureError(
      err,
      category: .audioCaptureFailed,
      stage: "recording",
      extra: SentryAudioExtras.buildCaptureExtras(
        route: route,
        sourceType: audioCapture.captureSourceType,
        sessionID: sessionID,
        isActivelyCapturing: audioCapture.isActivelyCapturing,
        inputDeviceUIDPreferred: audioCapture.preferredInputDeviceIDOverride.isEmpty
          ? nil : audioCapture.preferredInputDeviceIDOverride,
        inputDeviceUIDSystemDefault: AudioDeviceEnumerator.defaultInputDeviceUID(),
        failureMode: "zombie_engine_zero_peak",
        timeSinceLastSuccessfulRecordingMs:
          captureTelemetry
          .timeSinceLastSuccessfulRecordingMs(),
        configChangeCountSinceLaunch: captureTelemetry.configurationChangeCount
      )
    )
  }

  // polishExistingTranscript() removed — re-polish is now handled by TranscriptPolishService,
  // which is decoupled from pipeline state. See #206.

  /// Reset pipeline to idle state.
  public func reset() {
    guard !isStopping, !isStarting else { return }
    stopRequested = false
    pendingStallRecoveryToken = nil
    vadMonitorTask?.cancel()
    vadMonitorTask = nil
    // Cancel any active streaming ASR session to prevent orphaned sessions.
    let wasStreaming = streamingASRActive
    deactivateStreamingForwarding()
    if wasStreaming {
      Task { [weak self] in
        await self?.asrManager.cancelStreaming()
      }
    }
    if audioCapture.isCapturing {
      let capture = audioCapture
      Task { _ = await capture.stopCapture() }
    }
    silenceDetector = nil
    recordingStartTime = nil
    state = .idle
    currentTranscript = nil
  }

  /// Handle audio engine interruption (device disconnect, service crash, max duration cap).
  /// Called by AppState's unified interruption handler, not set directly on audioCapture.
  public func handleEngineInterruption() {
    pendingStallRecoveryToken = nil
    // Issue #285 — Sentry emission for audio/XPC interruptions is owned by
    // AppState.onXPCServiceError (single-owner per plan §3.4a). This handler
    // is control-flow only: clean up pipeline state + transition UI.
    SentryBreadcrumb.updateRecordingState(active: false)
    frozenSnapshot = nil
    vadMonitorTask?.cancel()
    vadMonitorTask = nil
    silenceDetector = nil
    if streamingASRActive {
      Task { [weak self] in
        await self?.asrManager.cancelStreaming()
      }
    }
    deactivateStreamingForwarding()
    // Reset capture state so isCapturing and warm engine timer are consistent.
    // The engine is already dead, but stopCapture() clears client-side flags.
    Task { [weak self] in
      _ = await self?.audioCapture.stopCapture()
    }
    targetApp = nil
    targetElement = nil
    recordingStartTime = nil
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
        userInfo: [NSLocalizedDescriptionKey: "ASR XPC service crashed"]),
      category: .xpcServiceError, stage: "asr",
      extra: ["was_recording": state == .recording],
      snapshot: snapshot
    )
    SentryBreadcrumb.updateRecordingState(active: false)
    frozenSnapshot = nil
    vadMonitorTask?.cancel()
    vadMonitorTask = nil
    silenceDetector = nil
    if streamingASRActive {
      deactivateStreamingForwarding()
    }
    // Stop audio capture — it's still running since only the ASR service died
    Task { [weak self] in
      await self?.audioCapture.stopCapture()
    }
    targetApp = nil
    targetElement = nil
    recordingStartTime = nil
    state = .error("Transcription service crashed — please try again")
  }

  /// Build a snapshot at interruption time when no frozen snapshot exists yet
  /// (e.g., XPC crash during recording before stopAndTranscribe is reached).
  private func buildInterruptionSnapshot() -> SentryBreadcrumb.RecordingSnapshot {
    if let existing = frozenSnapshot { return existing }
    let start = recordingStartTime ?? Date()
    return SentryBreadcrumb.RecordingSnapshot(
      backend: "parakeet",
      audioRoute: audioCapture.currentAudioRoute,
      wasStreaming: streamingASRActive,
      startTime: start,
      durationMs: Int(Date().timeIntervalSince(start) * 1000),
      targetAppBundleID: targetApp?.bundleIdentifier
    )
  }

  /// Cancel an active recording immediately without transcribing.
  /// Guards on `.recording` state — safe to call from any other state.
  public func cancelRecording() async {
    stopRequested = false
    pendingStallRecoveryToken = nil

    // Cancel during model loading: abort the load task and return to idle.
    if state == .loadingModel {
      modelLoadTask?.cancel()
      modelLoadTask = nil
      targetApp = nil
      targetElement = nil
      state = .idle
      return
    }

    guard state == .recording else { return }

    // Stop VAD monitoring task immediately
    vadMonitorTask?.cancel()
    vadMonitorTask = nil
    silenceDetector = nil

    // Deactivate streaming forwarding FIRST to prevent new buffer dispatches
    let wasStreaming = streamingASRActive
    deactivateStreamingForwarding()

    // Stop the audio engine and discard samples BEFORE awaiting cancelStreaming().
    // This is critical: stopCapture() sets the TapStoppedFlag which prevents
    // the real-time audio thread from creating any new Task allocations. If we
    // await cancelStreaming() first (which suspends), the audio engine continues
    // firing tap callbacks during the suspension, creating Tasks that race with
    // teardown and corrupt the heap.
    _ = await audioCapture.stopCapture()

    // Now cancel streaming ASR session (safe to await — engine is stopped)
    if wasStreaming {
      await asrManager.cancelStreaming()
    }

    // Clear target app/element reference — nothing will be pasted
    targetApp = nil
    targetElement = nil
    recordingStartTime = nil

    // Transition to idle without saving any transcript
    state = .idle
  }

  /// Deactivate streaming ASR buffer forwarding. Does not cancel the backend session.
  private func deactivateStreamingForwarding() {
    streamingASRActive = false
    audioCapture.onBufferCaptured = nil
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

  // MARK: - Streaming Rescue

  /// Attempt streaming finalize, fall back to batch if streaming fails or returns empty
  /// and VAD detected speech. Heart-level rescue: captured samples are already available,
  /// and batch uses a separate AsrManager from streaming's SlidingWindowAsrManager.
  private func transcribeWithStreamingRescue(
    samples: [Float],
    hasSpeechEvidence: Bool
  ) async throws -> ASRResult {
    // 1. Try streaming finalize (happy path)
    do {
      let result = try await asrManager.finalizeStreaming()
      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        return result
      }
      // Streaming returned empty -- check rescue eligibility below
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      await AppLogger.shared.log(
        "Streaming finalize failed: \(error.localizedDescription), checking rescue eligibility",
        level: .info, category: "Pipeline"
      )
    }

    // 2. No speech evidence means genuine silence, not a rescue candidate.
    // Return an empty result so the caller handles it with the appropriate message.
    guard hasSpeechEvidence else {
      return ASRResult(
        text: "", language: "en", duration: 0, processingTime: 0, backendType: .parakeet)
    }

    // 3. Batch rescue: speech was detected but streaming failed to decode it.
    await AppLogger.shared.log(
      "Streaming rescue: speech evidence found, retrying batch (\(samples.count) samples)",
      level: .info, category: "Pipeline"
    )

    let result = try await asrManager.transcribe(
      audioSamples: samples, options: transcriptionOptions)

    await AppLogger.shared.log(
      "Streaming rescue: batch produced \(result.text.count) chars",
      level: .info, category: "Pipeline"
    )

    return result
  }

  // MARK: - DictationPipeline Conformance

  public var overlayIntent: OverlayIntent {
    switch state {
    case .loadingModel:
      return .processing(label: "Loading model...")
    case .recording:
      return .recording(audioLevel: 0)  // actual level provided by AudioCaptureManager
    case .transcribing:
      return .processing(label: "Transcribing...")
    case .polishing:
      return .processing(label: "Polishing...")
    case .idle, .complete:
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

  /// Issue #289: dumb external-error sink. No transition side-effects, no
  /// retry scheduling — callers own the decision to surface an error here.
  public func setExternalError(_ message: String) {
    currentTranscript = nil
    state = .error(message)
  }

  /// Issue #289: see `DictationPipeline.clearPendingStallRecovery`.
  public func clearPendingStallRecovery() {
    pendingStallRecoveryToken = nil
  }

  /// Fan out frozen config values to substeps and derive decode options.
  /// Called once at `startRecording` after `currentSessionConfig` is set.
  /// `llmPolishStep` is written here rather than read via the config because
  /// its internal caches key off provider/model identity, and the
  /// `TranscriptPolishService` (re-polish path) keeps it live-synced
  /// between recordings.
  private func applySessionConfig(_ config: DictationSessionConfig) {
    llmPolishStep.llmProvider = config.llmProvider
    llmPolishStep.llmModel = config.llmModel
    llmPolishStep.polishInstructions = config.polishInstructions
    llmPolishStep.styleConfig = config.styleConfig
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

    var opts = TranscriptionOptions()
    switch config.languageMode {
    case .auto:
      opts.language = nil
    case .locked(let code):
      opts.language = code
    }
    transcriptionOptions = opts
  }
}
