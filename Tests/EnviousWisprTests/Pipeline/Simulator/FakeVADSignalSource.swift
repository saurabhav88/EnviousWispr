import Foundation

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

  /// The session each emitted signal is stamped with. PR-3 sets this per
  /// session start (mirroring the real seam being told the frozen session).
  var currentSessionID = SessionID()

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

  func speechEvidenceAtStop() -> VADSpeechEvidence {
    evidenceReadCount += 1
    return evidence
  }

  /// Close the signal stream at scenario teardown.
  func finish() {
    stopContinuation.finish()
  }
}
