import Foundation

@testable import EnviousWisprPipeline

// #1548 D1 — the recording FSM collapsed 14 states → 5 (`idle, arming, live,
// stopping, delivering`) and the seven ENDING categories moved onto a sibling
// `RecordingOutcome` that also carries the ending's payload (reason / cause /
// wasRecording flag). Before this change the suites asserted on bare terminal
// STATES (`kernel.state == .discarded`), and the reason lived on a separate
// observable (`discardReason`, `lastNoSpeechSource`) that these files never
// read. So the faithful translation of a pre-#1548 terminal-state assertion is
// PAYLOAD-AGNOSTIC: "the session concluded as a discard," not "…as a discard
// for THIS reason." `kind` erases the payload for exactly those assertions;
// tests that DO pin a reason keep the full `== .failed(.noAudioCaptured)` form.
extension RecordingOutcome {
  /// The ending CATEGORY with its associated payload erased — the pre-#1548
  /// bare-terminal vocabulary these suites asserted on.
  enum Kind: Equatable, Sendable {
    case completed
    case failed
    case cancelled
    case discarded
    case noSpeech
    case audioInterrupted
    case asrInterrupted
    case noTransport
  }

  var kind: Kind {
    switch self {
    case .completed: return .completed
    case .failed: return .failed
    case .cancelled: return .cancelled
    case .discarded: return .discarded
    case .noSpeech: return .noSpeech
    case .audioInterrupted: return .audioInterrupted
    case .asrInterrupted: return .asrInterrupted
    case .noTransport: return .noTransport
    }
  }
}

extension Optional where Wrapped == RecordingOutcome {
  /// `kernel.recordingOutcome.kind == .discarded` reads as the old
  /// `kernel.state == .discarded` did — nil (session not concluded) never
  /// matches a category.
  var kind: RecordingOutcome.Kind? { self?.kind }
}
