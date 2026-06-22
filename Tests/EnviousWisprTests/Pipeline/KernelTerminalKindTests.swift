import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #1063 PR2 — the crash-recovery cleanup signal classifies each kernel terminal
/// as DISCARD (delete the spool) or FAILURE (retain for next-launch recovery).
/// `matcher-set-adversarial-tests`: every terminal is exercised in BOTH semantic
/// classes, and the non-terminal / `.completed` / `.idle` states must map to nil
/// so the signal never fires for a saved take or a resting kernel.
@MainActor
@Suite("Kernel terminal-kind split (#1063 PR2)")
struct KernelTerminalKindTests {

  @Test("unambiguous discard terminals → .discard (delete the spool)")
  func discardTerminals() {
    #expect(KernelDictationDriver.endedWithoutSaveKind(for: .discarded) == .discard)
    #expect(KernelDictationDriver.endedWithoutSaveKind(for: .noSpeech) == .discard)
  }

  @Test("failure terminals → .failure (RETAIN the recoverable audio)")
  func failureTerminals() {
    #expect(
      KernelDictationDriver.endedWithoutSaveKind(for: .failed(.asrFailed)) == .failure)
    #expect(KernelDictationDriver.endedWithoutSaveKind(for: .audioInterrupted) == .failure)
    #expect(KernelDictationDriver.endedWithoutSaveKind(for: .asrInterrupted) == .failure)
  }

  @Test(".cancelled is excluded from the STATIC map (ambiguous — resolved dynamically)")
  func cancelledIsDynamic() {
    // `.cancelled` is reached by both a user cancel (delete) and a fault/system
    // cancel (retain), so the static map returns nil and the fire site resolves it
    // via the per-cancel disposition (Codex terminal-kind matrix).
    #expect(KernelDictationDriver.endedWithoutSaveKind(for: .cancelled) == nil)
  }

  @Test(".completed and .idle never fire the signal (saved / resting)")
  func completedAndIdleAreNil() {
    #expect(KernelDictationDriver.endedWithoutSaveKind(for: .completed) == nil)
    #expect(KernelDictationDriver.endedWithoutSaveKind(for: .idle) == nil)
  }

  @Test("non-terminal states never fire the signal")
  func nonTerminalsAreNil() {
    for state in [
      RecordingSessionState.preparing, .warmingUp, .recording, .stopping, .transcribing,
      .finalizing,
    ] {
      #expect(KernelDictationDriver.endedWithoutSaveKind(for: state) == nil)
    }
  }
}
