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
  /// Per-subscriber continuations (Codex r1 P1). Mirrors the production
  /// `CaptureVADSignalSource` shape so simulator coverage matches: every
  /// `emit` broadcasts to all live subscribers; iterator cancellation
  /// auto-removes its entry via `onTermination`.
  private var subscribers: [Int: AsyncStream<VADStopSignal>.Continuation] = [:]
  private var nextSubscriberID: Int = 0
  /// Per-subscriber continuations for the approaching-cap warning stream (#1060).
  private var warningSubscribers: [Int: AsyncStream<VADWarningSignal>.Continuation] = [:]
  private var nextWarningSubscriberID: Int = 0

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

  init() {}

  func subscribeStopSignals() -> AsyncStream<VADStopSignal> {
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

  func subscribeWarningSignals() -> AsyncStream<VADWarningSignal> {
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

  /// Number of approaching-cap warnings emitted — for warning-path tests.
  private(set) var emittedWarningCount = 0

  /// Emit an approaching-cap warning stamped with `currentSessionID` (#1060).
  func emitWarning(remainingSeconds: TimeInterval = 60) {
    emittedWarningCount += 1
    let signal = VADWarningSignal(remainingSeconds: remainingSeconds, sessionID: currentSessionID)
    for continuation in warningSubscribers.values { continuation.yield(signal) }
  }

  /// Emit a warning stamped with a PRIOR session's id — the stale-drop case.
  func emitStaleWarning(remainingSeconds: TimeInterval = 60) {
    emittedWarningCount += 1
    let signal = VADWarningSignal(remainingSeconds: remainingSeconds, sessionID: SessionID())
    for continuation in warningSubscribers.values { continuation.yield(signal) }
  }

  /// Emit one stop-driving signal, stamped with `currentSessionID` (driven by a
  /// scenario's `VADDirective`). Broadcast to every live subscriber.
  func emit(_ kind: VADStopKind) {
    emittedKinds.append(kind)
    let signal = VADStopSignal(kind: kind, sessionID: currentSessionID)
    for continuation in subscribers.values { continuation.yield(signal) }
  }

  /// Emit a stop-driving signal stamped with a PRIOR session's `SessionID` —
  /// the R2 stale-callback injection (PR-3 plan §3.6). A fresh `SessionID`
  /// distinct from `currentSessionID` models a callback latched under a
  /// finished session; the kernel must drop it (FSM invariant 7).
  func emitStale(_ kind: VADStopKind) {
    emittedKinds.append(kind)
    let signal = VADStopSignal(kind: kind, sessionID: SessionID())
    for continuation in subscribers.values { continuation.yield(signal) }
  }

  func speechEvidenceAtStop() -> VADSpeechEvidence {
    evidenceReadCount += 1
    return evidence
  }

  func speechSegmentsAtStop() -> [SpeechSegment] { segments }

  /// Close every subscriber's stream at scenario teardown.
  func finish() {
    for continuation in subscribers.values { continuation.finish() }
    subscribers.removeAll()
    for continuation in warningSubscribers.values { continuation.finish() }
    warningSubscribers.removeAll()
  }
}
