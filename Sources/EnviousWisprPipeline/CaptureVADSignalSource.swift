import EnviousWisprAudio
import Foundation

// MARK: - CaptureVADSignalSource (epic #827, PR-4 §3.5)
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
// It does NOT host the in-process VAD loop — that loop is a wiring concern
// (PR-4b). This source only aggregates and stamps signals.
//
// PR-4a ships this production-unwired: no App-layer caller binds it yet.

/// Vends the kernel's `VADSignalSource` by bridging the in-process and XPC VAD
/// signal origins (PR-1 §B.6, D7/D8).
@MainActor
final class CaptureVADSignalSource: VADSignalSource {

  private let signalStream: AsyncStream<VADStopSignal>
  private let signalContinuation: AsyncStream<VADStopSignal>.Continuation

  /// The session each emitted signal is stamped with. The seam is told the
  /// frozen session at session start (PR-1 §B.6 — VAD config is per-session);
  /// the kernel drops a signal whose `sessionID` is not its current session.
  private var currentSessionID = SessionID()

  /// Computes the tri-state speech verdict at `stopping`. Defaults to
  /// `.unavailable` (no detector) — the kernel then does not gate (PR-1 §B.6).
  private var evidenceProvider: @MainActor () -> VADSpeechEvidence

  init(
    evidenceProvider: @escaping @MainActor () -> VADSpeechEvidence = { .unavailable }
  ) {
    (signalStream, signalContinuation) = AsyncStream.makeStream(of: VADStopSignal.self)
    self.evidenceProvider = evidenceProvider
  }

  // MARK: VADSignalSource

  var stopSignals: AsyncStream<VADStopSignal> { signalStream }

  func speechEvidenceAtStop() -> VADSpeechEvidence { evidenceProvider() }

  // MARK: Session wiring

  /// Update the session stamp — the wiring calls this at session start so
  /// every subsequent signal carries the live `SessionID` (PR-1 §B.6).
  func setCurrentSessionID(_ id: SessionID) {
    currentSessionID = id
  }

  /// Replace the speech-evidence provider for the session — the wiring sets it
  /// from the in-process `SilenceDetector.speechSegments` or the XPC
  /// `captureResult.vadSegments` (PR-4 §3.5).
  func setEvidenceProvider(_ provider: @escaping @MainActor () -> VADSpeechEvidence) {
    evidenceProvider = provider
  }

  /// Claim sole ownership of `AudioCaptureInterface.onVADAutoStop` (PR-4 §3.5).
  /// The XPC service-side detector fires this callback; the kernel no longer
  /// binds it directly (`bindCaptureCallbacks` dropped that wiring).
  func bind(audioCapture: any AudioCaptureInterface) {
    audioCapture.onVADAutoStop = { [weak self] in
      self?.noteAutoStopTriggered()
    }
  }

  // MARK: Signal inputs

  /// Record a silence-hangover auto-stop — from the XPC `onVADAutoStop`
  /// callback or the in-process VAD loop. Stamped with the current session.
  func noteAutoStopTriggered() {
    signalContinuation.yield(
      VADStopSignal(kind: .autoStopTriggered, sessionID: currentSessionID))
  }

  /// Record a max-duration stop. Stamped with the current session.
  func noteMaxDurationReached() {
    signalContinuation.yield(
      VADStopSignal(kind: .maxDurationReached, sessionID: currentSessionID))
  }
}
