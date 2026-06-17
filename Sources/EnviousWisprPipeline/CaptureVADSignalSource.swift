import EnviousWisprAudio
import EnviousWisprCore
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

  init(
    evidenceProvider: @escaping @MainActor () -> VADSpeechEvidence = { .unavailable },
    segmentsProvider: @escaping @MainActor () -> [SpeechSegment] = { [] }
  ) {
    self.evidenceProvider = evidenceProvider
    self.segmentsProvider = segmentsProvider
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

  /// Claim sole ownership of `AudioCaptureInterface.onVADAutoStop` (PR-4 §3.5).
  /// The XPC service-side detector fires this callback; the kernel no longer
  /// binds it directly (`bindCaptureCallbacks` dropped that wiring).
  func bind(audioCapture: any AudioCaptureInterface) {
    self.audioCapture = audioCapture
    audioCapture.onVADAutoStop = { [weak self] in
      self?.noteAutoStopTriggered()
    }
  }

  /// Bind the frozen per-session VAD config. The kernel calls this before the
  /// recording phase so direct and XPC capture paths feed the same source.
  func configureSession(config: DictationSessionConfig, audioCapture: any AudioCaptureInterface) {
    self.audioCapture = audioCapture
    sessionConfig = config
    monitorTask?.cancel()
    monitorTask = nil
    if detectorSilenceTimeout != nil && detectorSilenceTimeout != config.vadSilenceTimeout {
      silenceDetector = nil
      detectorSilenceTimeout = nil
    }
    directDetectorPrepared = false
    setEvidenceProvider { .unavailable }
    setSegmentsProvider { [] }
  }

  /// Start direct-mode VAD monitoring and max-duration monitoring. In XPC mode
  /// the service owns the detector and calls `onVADAutoStop`; this loop still
  /// owns max-duration so the kernel receives the same stop signal in both
  /// modes.
  func startMonitoring(
    recordingStartTime: Date,
    isRecording: @escaping @MainActor () -> Bool
  ) {
    guard let audioCapture, let config = sessionConfig else { return }
    let isXPCMode = audioCapture is AudioCaptureProxy

    monitorTask?.cancel()
    monitorTask = Task { @MainActor [weak self] in
      guard let self, let audioCapture = self.audioCapture else { return }
      let detector: SilenceDetector?

      if isXPCMode {
        detector = nil
      } else {
        let vadConfig = SmoothedVADConfig.fromSensitivity(
          config.vadSensitivity,
          energyGate: config.vadEnergyGate
        )
        let directDetector =
          self.silenceDetector
          ?? SilenceDetector(
            silenceTimeout: config.vadSilenceTimeout,
            vadConfig: vadConfig
          )
        self.silenceDetector = directDetector
        self.detectorSilenceTimeout = config.vadSilenceTimeout
        await directDetector.reset()
        await directDetector.updateConfig(vadConfig)
        if !(await directDetector.isReady) {
          do {
            try await directDetector.prepare()
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
        self.directDetectorPrepared = true
        detector = directDetector
      }

      await self.runMonitor(
        detector: detector,
        config: config,
        recordingStartTime: recordingStartTime,
        audioCapture: audioCapture,
        isRecording: isRecording
      )
    }
  }

  func finalizeAtStop(rawSampleCount: Int, xpcSegments: [SpeechSegment]) async {
    monitorTask?.cancel()
    monitorTask = nil

    if audioCapture is AudioCaptureProxy {
      setSegmentsProvider { xpcSegments }
      setEvidenceProvider { xpcSegments.isEmpty ? .confirmedNoSpeech : .voiced }
      return
    }

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
    isRecording: @escaping @MainActor () -> Bool
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
