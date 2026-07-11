import Foundation

// MARK: - Recording-session FSM state vocabulary (epic #827, PR-1 §B.1.1)
//
// This is the harness's *assertion vocabulary* — the canonical state set every
// scenario's `ExpectedOutcome` is written against. It is NOT the kernel's FSM
// type: PR-3's `RecordingSessionKernel` owns the real state machine, and PR-3's
// test-side `RecordingSessionDriving` conformer maps the kernel's state onto
// this enum. Lives in the test target for exactly that reason — it is test
// scaffolding, not a production type (PR-2 plan §3.0, §3.8).

/// A normalized, recoverable failure reason for the `failed` terminal state
/// (PR-1 §B.1.2 transition table).
enum FSMFailureReason: Equatable, Sendable {
  case prepareFailed
  case permissionDenied
  case modelWedged
  case modelLoadFailed
  case captureStartFailed
  case noAudioCaptured
  case asrEmpty
  case asrFailed
  case asrWedged
  case emptyAfterProcessing
  case captureStalled
  case zeroSignal
}

/// The recording-session FSM states (PR-1 §B.1.1). Seven are terminal:
/// `completed`, `failed`, `cancelled`, `discarded`, `noSpeech`,
/// `audioInterrupted`, `asrInterrupted`. Exactly one terminal state is reached
/// per session.
enum FSMState: Equatable, Sendable {
  case idle
  case preparing
  case warmingUp
  case recording
  case stopping
  case transcribing
  case finalizing
  // Terminal states.
  case completed
  case failed(FSMFailureReason)
  case cancelled
  case discarded
  case noSpeech
  case audioInterrupted
  case asrInterrupted

  /// `true` for the seven terminal states (PR-1 §B.1.1).
  var isTerminal: Bool {
    switch self {
    case .completed, .failed, .cancelled, .discarded, .noSpeech,
      .audioInterrupted, .asrInterrupted:
      return true
    case .idle, .preparing, .warmingUp, .recording, .stopping, .transcribing,
      .finalizing:
      return false
    }
  }
}

/// The user-visible error surface a terminal state renders (PR-1 §B.1.3).
/// `audioInterrupted` renders `.interruption`; `asrInterrupted` and `failed`
/// render `.recoverableError`; the silent terminals render nothing.
enum ErrorCategory: Equatable, Sendable {
  case recoverableError
  case interruption
}
