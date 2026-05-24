import Foundation

@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

// MARK: - FakeVADSignalSource (epic #827, PR-2 plan §3.3; PR-1 §B.6)
//
// Conforms to the production `VADSignalSource` seam. Emits the stop-driving
// signals on command and vends a settable speech-evidence verdict, so
// VAD-policy scenarios (auto-stop, no-speech gate, evidence-unavailable) run
// deterministically.

@MainActor
final class FakeVADSignalSource: VADSignalSource {
  let stopSignals: AsyncStream<VADStopSignal>
  private let stopContinuation: AsyncStream<VADStopSignal>.Continuation

  /// The verdict `speechEvidenceAtStop()` returns. Defaults to `.voiced`;
  /// scenarios set `.confirmedNoSpeech` or `.unavailable`.
  var evidence: VADSpeechEvidence = .voiced

  /// The segments `speechSegmentsAtStop()` returns (PR-4.5 #5, Codex r1).
  /// Defaults empty; conductor-parity seam tests set non-empty to assert
  /// the conditioner reads from the seam, not from `CaptureResult.vadSegments`.
  var segments: [SpeechSegment] = []

  /// The session each emitted signal is stamped with. The kernel calls
  /// `setCurrentSessionID(_:)` at session start (PR-4.5 #2); tests may also
  /// poke this directly to model out-of-band stamp injection.
  var currentSessionID = SessionID()

  func setCurrentSessionID(_ id: SessionID) {
    currentSessionID = id
  }

  /// Every signal kind emitted, in order — for `FakeVADSignalSourceTests`.
  private(set) var emittedKinds: [VADStopKind] = []
  /// Number of times `speechEvidenceAtStop()` was read.
  private(set) var evidenceReadCount = 0

  init() {
    (stopSignals, stopContinuation) = AsyncStream.makeStream(of: VADStopSignal.self)
  }

  /// Emit one stop-driving signal, stamped with `currentSessionID` (driven by a
  /// scenario's `VADDirective`).
  func emit(_ kind: VADStopKind) {
    emittedKinds.append(kind)
    stopContinuation.yield(VADStopSignal(kind: kind, sessionID: currentSessionID))
  }

  /// Emit a stop-driving signal stamped with a PRIOR session's `SessionID` —
  /// the R2 stale-callback injection (PR-3 plan §3.6). A fresh `SessionID`
  /// distinct from `currentSessionID` models a callback latched under a
  /// finished session; the kernel must drop it (FSM invariant 7).
  func emitStale(_ kind: VADStopKind) {
    emittedKinds.append(kind)
    stopContinuation.yield(VADStopSignal(kind: kind, sessionID: SessionID()))
  }

  func speechEvidenceAtStop() -> VADSpeechEvidence {
    evidenceReadCount += 1
    return evidence
  }

  func speechSegmentsAtStop() -> [SpeechSegment] { segments }

  /// Close the signal stream at scenario teardown.
  func finish() {
    stopContinuation.finish()
  }
}
