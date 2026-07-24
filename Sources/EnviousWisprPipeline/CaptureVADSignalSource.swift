import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation

// MARK: - CaptureVADSignalSource type — epic #827, PR-4 §3.5
//
// The production `VADSignalSource` conformer (PR-1 §B.6). No production
// conformer existed before PR-4 — only the test `FakeVADSignalSource`.
//
// The kernel owns VAD *policy* (auto-stop, the no-speech gate, max-duration);
// the capture/VAD seam owns VAD *signal production*. This source is the seam:
// a thin event aggregator that unifies the two VAD signal origins into the one
// normalized `stopSignals` stream the kernel subscribes to —
//   - the XPC service-side detector, surfaced through
//     `AudioCaptureInterface.onVADAutoStop` (this source is its single owner);
//   - the in-process `SilenceDetector` auto-stop, delivered through
//     `noteAutoStopTriggered()` by the VAD-loop wiring;
//   - the max-duration stop, delivered through `noteMaxDurationReached()`.
//
// It also owns the in-process direct-mode VAD loop, because that loop is the
// production signal source when capture is not running through XPC. Both modes
// normalize into the same kernel input port.
//
// PR-4a ships this production-unwired: no App-layer caller binds it yet.

/// Vends the kernel's `VADSignalSource` by bridging the in-process and XPC VAD
/// signal origins (PR-1 §B.6, D7/D8). Widened from `internal` to `package` in
/// PR-5 Rung 5 so the App-owned shared instance can be passed across the
/// `package`-level `KernelDictationDriverFactory.ParakeetInputs` /
/// `WhisperKitInputs` seams (Codex r2 new defect 1 / r3 new defect 1).
@MainActor
package final class CaptureVADSignalSource: VADSignalSource {

  /// Per-subscriber continuations keyed by an auto-incrementing id. Codex
  /// code-diff r1 P1 (PR-5 Rung 5): each `subscribeStopSignals()` call
  /// registers a fresh continuation here; `noteAutoStopTriggered` /
  /// `noteMaxDurationReached` broadcast to every live entry. Iterator
  /// cancellation removes its own entry via `onTermination`.
  private var subscribers: [Int: AsyncStream<VADStopSignal>.Continuation] = [:]
  private var nextSubscriberID: Int = 0
  /// Per-subscriber continuations for the separate approaching-cap warning
  /// stream (#1060). Mirrors `subscribers` but for `VADWarningSignal` (advisory,
  /// never stop-driving). Kept distinct so warnings can never ride the stop path.
  private var warningSubscribers: [Int: AsyncStream<VADWarningSignal>.Continuation] = [:]
  private var nextWarningSubscriberID: Int = 0
  private weak var audioCapture: (any AudioCaptureInterface)?
  private var monitorTask: Task<Void, Never>?
  private var silenceDetector: SilenceDetector?
  private var detectorSilenceTimeout: TimeInterval?
  private var directDetectorPrepared = false

  /// #1224 (ported in-process at the C1 XPC collapse, #1543): classifies the
  /// bundled VAD model's health at most once per process and decides
  /// notice-eligibility on every recording. The helper used to own this; with
  /// capture in-process the pipeline's direct-mode VAD loop is the only place
  /// the model is loaded.
  private var vadReadinessTracker = VADModelReadinessTracker()

  /// Typed readiness FACT, bound by the App shell (BIBLE §detectors-report-facts:
  /// the source never carries the sentence). Fires when the bundled model is
  /// broken, auto-stop is on, and a recording is live — the App authors the
  /// user-facing "auto-stop unavailable" copy in the bound closure.
  package var onAutoStopUnavailableNotice: (@MainActor () -> Void)?

  /// The session each emitted signal is stamped with. The seam is told the
  /// frozen session at session start (PR-1 §B.6 — VAD config is per-session);
  /// the kernel drops a signal whose `sessionID` is not its current session.
  private var currentSessionID = SessionID()

  /// Computes the tri-state speech verdict at `stopping`. Defaults to
  /// `.unavailable` (no detector) — the kernel then does not gate (PR-1 §B.6).
  private var evidenceProvider: @MainActor () -> VADSpeechEvidence

  /// Returns the voiced segments observed during the just-stopped session
  /// (PR-4.5 #5, Codex r1). Default `[]` (no detector ran). The wiring sets
  /// it from `captureResult.vadSegments` (XPC) or `detector.speechSegments`
  /// (direct mode) — see `setSegmentsProvider`.
  private var segmentsProvider: @MainActor () -> [SpeechSegment]
  private var sessionConfig: DictationSessionConfig?

  /// Monotonic monitor-run identity (#1780). A session id alone is NOT a
  /// sufficient staleness guard: `finalizeAtStop` cancels a run without
  /// changing the session, and a replacement can reuse the same session, so a
  /// resumed old task would still pass a session-only check and emit into the
  /// wrong run. Bumped by `invalidateMonitor()` at every cancellation site.
  private var monitorGeneration: UInt64 = 0

  /// Test seam (#1780): produces the detector `startMonitoring` would build
  /// itself. Internal and defaulted, so production construction is unchanged;
  /// tests inject a detector backed by a continuation-controlled fake so
  /// preparation and first-chunk suspension are deterministic.
  private let makeDetector: @MainActor (TimeInterval, SmoothedVADConfig) -> SilenceDetector

  /// Dual-channel record-start markers (#1780). Injected so tests observe with
  /// per-instance spies rather than global Sentry/PostHog hooks.
  private let recordStartTelemetry: RecordStartTelemetrySink

  init(
    evidenceProvider: @escaping @MainActor () -> VADSpeechEvidence = { .unavailable },
    segmentsProvider: @escaping @MainActor () -> [SpeechSegment] = { [] },
    makeDetector: @escaping @MainActor (TimeInterval, SmoothedVADConfig) -> SilenceDetector = {
      timeout, vadConfig in
      SilenceDetector(silenceTimeout: timeout, vadConfig: vadConfig)
    },
    recordStartTelemetry: RecordStartTelemetrySink = RecordStartTelemetrySink()
  ) {
    self.evidenceProvider = evidenceProvider
    self.segmentsProvider = segmentsProvider
    self.makeDetector = makeDetector
    self.recordStartTelemetry = recordStartTelemetry
  }

  /// Sole authority for ending a monitor run (#1780). Cancels, clears, and
  /// advances the generation together — separating them is what let a resumed
  /// task emit into a newer run.
  private func invalidateMonitor() {
    monitorTask?.cancel()
    monitorTask = nil
    monitorGeneration += 1
  }

  /// A captured run may emit only while its session and generation are still
  /// current AND the recording is still live. Checked immediately before every
  /// marker, with no await or mutable read between the check and the emit.
  ///
  /// The liveness term is load-bearing and not redundant with the other two.
  /// `RecordingSessionKernel` concludes a session through ~40 `finishTerminal`
  /// sites — cancellation, capture-start failure, model wedge, capture stall,
  /// ASR failure — and only the normal stop path reaches `finalizeAtStop`. On
  /// every other terminal the session id and the generation are BOTH unchanged,
  /// so a task suspended in preparation or in first-chunk processing would wake
  /// after the recording had already ended and emit a marker into a concluded
  /// session. `isRecording` is the kernel's own liveness predicate
  /// (`state == .live && currentSessionID == sid`), so it goes false on every
  /// terminal path by construction, including any added later. It is passed per
  /// run rather than stored, so a new run's predicate can never be read by an
  /// older one.
  private func monitorIsCurrent(
    sessionID: SessionID,
    generation: UInt64,
    isRecording: @MainActor () -> Bool
  ) -> Bool {
    currentSessionID == sessionID && monitorGeneration == generation && isRecording()
  }

  // MARK: VADSignalSource (PR-5 Rung 5: package-required because the
  // type widened from internal to package; the protocol is public so
  // conforming members must be at least package.)

  package func subscribeStopSignals() -> AsyncStream<VADStopSignal> {
    let id = nextSubscriberID
    nextSubscriberID += 1
    return AsyncStream { continuation in
      subscribers[id] = continuation
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { @MainActor [weak self] in
          self?.subscribers.removeValue(forKey: id)
        }
      }
    }
  }

  package func subscribeWarningSignals() -> AsyncStream<VADWarningSignal> {
    let id = nextWarningSubscriberID
    nextWarningSubscriberID += 1
    return AsyncStream { continuation in
      warningSubscribers[id] = continuation
      continuation.onTermination = { @Sendable [weak self] _ in
        Task { @MainActor [weak self] in
          self?.warningSubscribers.removeValue(forKey: id)
        }
      }
    }
  }

  package func speechEvidenceAtStop() -> VADSpeechEvidence { evidenceProvider() }

  package func speechSegmentsAtStop() -> [SpeechSegment] { segmentsProvider() }

  // MARK: Session wiring

  /// Update the session stamp — the wiring calls this at session start so
  /// every subsequent signal carries the live `SessionID` (PR-1 §B.6).
  package func setCurrentSessionID(_ id: SessionID) {
    currentSessionID = id
  }

  /// Replace the speech-evidence provider for the session — the wiring sets it
  /// from the in-process `SilenceDetector.speechSegments` or the XPC
  /// `captureResult.vadSegments` (PR-4 §3.5).
  func setEvidenceProvider(_ provider: @escaping @MainActor () -> VADSpeechEvidence) {
    evidenceProvider = provider
  }

  /// Replace the voiced-segments provider for the session (PR-4.5 #5, Codex
  /// r1). The wiring sets it from `captureResult.vadSegments` (XPC mode) or
  /// from the in-process `SilenceDetector.speechSegments` (direct mode). The
  /// kernel's `CapturedAudioConditioner` reads this — NOT
  /// `CaptureResult.vadSegments` — so direct-mode recordings get the same
  /// VAD filtering as XPC mode.
  func setSegmentsProvider(_ provider: @escaping @MainActor () -> [SpeechSegment]) {
    segmentsProvider = provider
  }

  /// Claim sole ownership of `AudioCaptureInterface.onVADAutoStop` AND
  /// `onMaxDurationReached` (PR-4 §3.5; #1408 A3). The XPC service-side
  /// detector fires the first; the manager's hard sample-count backstop fires
  /// the second — both funnel into the ONE typed `VADStopSignal` route, so the
  /// kernel receives the same session-stamped, stale-drop-protected stop
  /// signal whichever mechanism noticed first. The kernel no longer binds
  /// either directly (`bindCaptureCallbacks` dropped that wiring).
  func bind(audioCapture: any AudioCaptureInterface) {
    self.audioCapture = audioCapture
    audioCapture.onVADAutoStop = { [weak self] in
      self?.noteAutoStopTriggered()
    }
    audioCapture.onMaxDurationReached = { [weak self] in
      self?.noteMaxDurationReached()
    }
  }

  /// Bind the frozen per-session VAD config. The kernel calls this before the
  /// recording phase so direct and XPC capture paths feed the same source.
  func configureSession(config: DictationSessionConfig, audioCapture: any AudioCaptureInterface) {
    self.audioCapture = audioCapture
    sessionConfig = config
    invalidateMonitor()
    if detectorSilenceTimeout != nil && detectorSilenceTimeout != config.vadSilenceTimeout {
      silenceDetector = nil
      detectorSilenceTimeout = nil
    }
    directDetectorPrepared = false
    setEvidenceProvider { .unavailable }
    setSegmentsProvider { [] }
  }

  /// Start direct-mode VAD monitoring and max-duration monitoring. Capture is
  /// always in-process (the separate capture helper was deleted at C1 #1543):
  /// this loop owns the `SilenceDetector` and the max-duration stop.
  func startMonitoring(
    recordingStartTime: Date,
    backend: String,
    isRecording: @escaping @MainActor () -> Bool
  ) {
    guard let audioCapture, let config = sessionConfig else { return }

    invalidateMonitor()

    // Snapshot every telemetry identity fact SYNCHRONOUSLY, before the task
    // exists (#1780). Reading these inside the task is unsafe: the task may
    // first execute after a later session has been stamped, which would
    // silently attribute this run's markers to the next recording.
    let runSessionID = currentSessionID
    let runGeneration = monitorGeneration
    let runBackend = backend
    let runInputRoute = audioCapture.currentAudioRoute

    monitorTask = Task { @MainActor [weak self, audioCapture] in
      guard let self else { return }
      // Reject a run already superseded before it first executed, BEFORE it
      // mutates retained detector state.
      guard self.monitorIsCurrent(
        sessionID: runSessionID, generation: runGeneration, isRecording: isRecording) else {
        return
      }

      let vadConfig = SmoothedVADConfig.fromSensitivity(
        config.vadSensitivity,
        energyGate: config.vadEnergyGate
      )
      let directDetector =
        self.silenceDetector
        ?? self.makeDetector(config.vadSilenceTimeout, vadConfig)
      // #1780: `model_reused` MUST be read here, before any preparation. Read
      // afterwards it would be true for every successful preparation and carry
      // no information. `reset()` does not unload the model, so `true` means
      // this retained detector entered the run already loaded.
      let modelReused = await directDetector.isReady
      // Invalidation can land during that actor await; re-check BEFORE taking
      // ownership of the retained detector, or a superseded run would rewrite
      // `silenceDetector`/`detectorSilenceTimeout` under the live run.
      guard self.monitorIsCurrent(
        sessionID: runSessionID, generation: runGeneration, isRecording: isRecording) else {
        return
      }
      self.silenceDetector = directDetector
      self.detectorSilenceTimeout = config.vadSilenceTimeout
      await directDetector.reset()
      await directDetector.updateConfig(vadConfig)

      // #1224 (ported in-process at C1 #1543): classify the bundled model's
      // health at most once per process, then check notice-eligibility on
      // EVERY recording. The eligibility check MUST stay outside the classify
      // branch, else the notice is lost when the model was classified while
      // auto-stop was off and enabled later (VADModelReadinessTrackerTests).
      await self.updateVADReadinessAndMaybeNotify(
        detector: directDetector, config: config, isRecording: isRecording)

      // Always run the monitor (#1543 Codex r2 P2). With a prepared detector it
      // does silence auto-stop AND the graceful max-duration cap; with a broken
      // model (nil detector) it still enforces the max-duration cap + the
      // approaching-cap warning — only the silence-auto-stop limb is lost. The
      // old XPC topology likewise ran a nil-detector host-side monitor.
      let ready = await directDetector.isReady
      // Same reason: `directDetectorPrepared` is live source state and must not
      // be written by a run that was superseded during preparation.
      guard self.monitorIsCurrent(
        sessionID: runSessionID, generation: runGeneration, isRecording: isRecording) else {
        return
      }
      if ready { self.directDetectorPrepared = true }

      // Re-check immediately before emitting: this point follows detector actor
      // awaits, so the run may have been invalidated while suspended. No await
      // or mutable read between the guard and the emit.
      guard self.monitorIsCurrent(
        sessionID: runSessionID, generation: runGeneration, isRecording: isRecording) else {
        return
      }
      self.recordStartTelemetry.vadPreparationCompleted(
        backend: runBackend, inputRoute: runInputRoute,
        ready: ready, modelReused: modelReused)

      await self.runMonitor(
        detector: ready ? directDetector : nil,
        config: config,
        recordingStartTime: recordingStartTime,
        audioCapture: audioCapture,
        isRecording: isRecording,
        runSessionID: runSessionID,
        runGeneration: runGeneration,
        runBackend: runBackend,
        runInputRoute: runInputRoute
      )
    }
  }

  /// Classify the bundled VAD model at most once per process, emit in-process
  /// handled-error telemetry on failure (the app can reach PostHog +
  /// SentryBreadcrumb; the deleted helper could not), then decide
  /// notice-eligibility on EVERY call — the eligibility check outside the
  /// classify branch is what closes the "classified while auto-stop off, never
  /// told after turning it on" trap (#1224).
  private func updateVADReadinessAndMaybeNotify(
    detector: SilenceDetector,
    config: DictationSessionConfig,
    isRecording: @escaping @MainActor () -> Bool
  ) async {
    // Load the model into THIS detector instance whenever it isn't already
    // loaded — NOT gated on the process-wide readiness tracker (#1543 Codex r2
    // P1). A fresh instance is created every time the silence-timeout setting
    // changes (`configureSession` discards the prior one), so gating on the
    // once-per-process tracker would leave that new instance unprepared and
    // silently disable auto-stop until relaunch. A model already classified
    // broken will fail again, so skip the retry (and its duplicate telemetry);
    // the notice-eligibility check below still runs every recording.
    let alreadyBroken: Bool = {
      if case .broken = vadReadinessTracker.readiness { return true } else { return false }
    }()
    if !(await detector.isReady), !alreadyBroken {
      do {
        try await detector.prepare()
        vadReadinessTracker.classifyIfNeeded(failureReason: nil)
      } catch {
        let reason = String(reflecting: type(of: error))
        vadReadinessTracker.classifyIfNeeded(failureReason: reason)
        // Reached only when NOT already broken (guard above), so at most: once
        // on the first unknown->broken classification, plus a per-occurrence
        // transient failure of a fresh detector — both bounded. A permanently
        // broken model skips this block after the first pass, so no per-recording
        // telemetry spam.
        SentryBreadcrumb.add(
          stage: "vad", message: "vad#prepare_failed", level: .warning,
          data: ["source": "bundle_missing", "reason": reason])
        TelemetryService.shared.limbFailureObserved(
          limb: "vad", operation: "prepare", result: "model_unavailable",
          errorCategory: reason, durationMs: nil)
      }
    }

    // Notice: auto-stop cannot run this recording. Two distinct causes (#1543
    // Codex r4): a PERMANENTLY broken bundled model uses the #1224 once-ever
    // one-shot (`shouldShowNotice`); a TRANSIENT per-detector prepare failure —
    // a fresh instance (after a silence-timeout change) that failed to load even
    // though the model classified `.ready` earlier — surfaces per affected
    // recording and self-limits (a healthy instance next recording is ready).
    guard config.vadAutoStop, isRecording() else { return }
    let brokenNow: Bool = {
      if case .broken = vadReadinessTracker.readiness { return true } else { return false }
    }()
    if brokenNow {
      if vadReadinessTracker.shouldShowNotice(autoStopEnabled: true, recordingIsLive: true) {
        onAutoStopUnavailableNotice?()
      }
    } else if !(await detector.isReady) {
      onAutoStopUnavailableNotice?()
    }
  }

  func finalizeAtStop(rawSampleCount: Int) async {
    invalidateMonitor()

    guard let silenceDetector, directDetectorPrepared else {
      setSegmentsProvider { [] }
      setEvidenceProvider { .unavailable }
      return
    }

    await silenceDetector.finalizeSegments(totalSampleCount: rawSampleCount)
    let segments = await silenceDetector.speechSegments
    setSegmentsProvider { segments }
    setEvidenceProvider { segments.isEmpty ? .confirmedNoSpeech : .voiced }
  }

  private func runMonitor(
    detector: SilenceDetector?,
    config: DictationSessionConfig,
    recordingStartTime: Date,
    audioCapture: any AudioCaptureInterface,
    isRecording: @escaping @MainActor () -> Bool,
    runSessionID: SessionID,
    runGeneration: UInt64,
    runBackend: String,
    runInputRoute: String
  ) async {
    await VADMonitorLoop.run(
      detector: detector,
      vadAutoStop: config.vadAutoStop,
      maxDuration: TimingConstants.maxRecordingDuration,
      warningLead: TimingConstants.maxDurationWarningLeadSeconds,
      recordingStartTime: recordingStartTime,
      sampleProvider: { audioCapture.capturedSamples },
      isRecording: isRecording,
      onApproachingMaxDuration: { [weak self] remainingSeconds in
        self?.noteApproachingMaxDuration(remainingSeconds: remainingSeconds)
      },
      onStop: { [weak self] reason in
        switch reason {
        case .silenceTimeout:
          self?.noteAutoStopTriggered()
        case .maxDuration:
          self?.noteMaxDurationReached()
        }
      },
      // #1780 first-chunk markers. Both callbacks carry the values captured
      // before the task existed and re-check run identity immediately before
      // emitting — a first-chunk await can resume after invalidation.
      onFirstChunkStarted: { [weak self] monitorMs in
        guard let self,
          self.monitorIsCurrent(
        sessionID: runSessionID, generation: runGeneration, isRecording: isRecording)
        else { return }
        self.recordStartTelemetry.firstChunkStarted(
          backend: runBackend, inputRoute: runInputRoute,
          monitorToFirstChunkMs: monitorMs)
      },
      onFirstChunkCompleted: { [weak self] latencyMs, shouldStop in
        guard let self,
          self.monitorIsCurrent(
        sessionID: runSessionID, generation: runGeneration, isRecording: isRecording)
        else { return }
        self.recordStartTelemetry.firstChunkCompleted(
          backend: runBackend, inputRoute: runInputRoute,
          chunkProcessingLatencyMs: latencyMs, shouldStop: shouldStop)
      }
    )
  }

  // MARK: Signal inputs

  /// Record a silence-hangover auto-stop — from the XPC `onVADAutoStop`
  /// callback or the in-process VAD loop. Stamped with the current session.
  /// Broadcast to every live subscriber (Codex r1 P1).
  func noteAutoStopTriggered() {
    broadcast(VADStopSignal(kind: .autoStopTriggered, sessionID: currentSessionID))
  }

  /// Record a max-duration stop. Stamped with the current session.
  /// Broadcast to every live subscriber (Codex r1 P1).
  func noteMaxDurationReached() {
    broadcast(VADStopSignal(kind: .maxDurationReached, sessionID: currentSessionID))
  }

  private func broadcast(_ signal: VADStopSignal) {
    for continuation in subscribers.values { continuation.yield(signal) }
  }

  /// Record an approaching-cap warning (#1060). Advisory — does NOT stop the
  /// recording. Stamped with the current session; broadcast to every live
  /// warning subscriber. Fired at most once per recording by `VADMonitorLoop`.
  func noteApproachingMaxDuration(remainingSeconds: TimeInterval) {
    broadcastWarning(
      VADWarningSignal(remainingSeconds: remainingSeconds, sessionID: currentSessionID))
  }

  private func broadcastWarning(_ signal: VADWarningSignal) {
    for continuation in warningSubscribers.values { continuation.yield(signal) }
  }
}
