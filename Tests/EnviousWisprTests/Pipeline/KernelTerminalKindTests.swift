import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #1063 PR2 / #1548 D1 — the crash-recovery cleanup signal classifies each
/// concluded session's `RecordingOutcome` as DISCARD (delete the spool) or
/// FAILURE (retain for next-launch recovery). `matcher-set-adversarial-tests`:
/// every outcome is exercised in BOTH semantic classes, and `.completed` /
/// `.cancelled` map to nil so the signal never fires for a saved take or is
/// left to the dynamic cancel disposition.
@MainActor
@Suite("Kernel terminal-kind split (#1063 PR2, #1548 D1)")
struct KernelTerminalKindTests {

  @Test("unambiguous discard outcomes → .discard (delete the spool)")
  func discardOutcomes() {
    #expect(
      KernelDictationDriver.endedWithoutSaveKind(for: .discarded(.tooShort)) == .discard)
    #expect(
      KernelDictationDriver.endedWithoutSaveKind(for: .discarded(.releasedBeforeRecording))
        == .discard)
    #expect(KernelDictationDriver.endedWithoutSaveKind(for: .noSpeech(.vadGate)) == .discard)
    #expect(
      KernelDictationDriver.endedWithoutSaveKind(for: .noSpeech(.asrEmptyNoSpeech)) == .discard)
  }

  @Test("failure outcomes → .failure (RETAIN the recoverable audio)")
  func failureOutcomes() {
    #expect(
      KernelDictationDriver.endedWithoutSaveKind(for: .failed(.asrFailed)) == .failure)
    #expect(
      KernelDictationDriver.endedWithoutSaveKind(for: .audioInterrupted(.engineLost))
        == .failure)
    #expect(
      KernelDictationDriver.endedWithoutSaveKind(for: .audioInterrupted(nil)) == .failure)
    #expect(
      KernelDictationDriver.endedWithoutSaveKind(for: .asrInterrupted(wasRecording: true))
        == .failure)
    #expect(
      KernelDictationDriver.endedWithoutSaveKind(for: .asrInterrupted(wasRecording: false))
        == .failure)
    // #1548 D1: the new no-transport outcome RETAINS (parity with
    // `.failed(.noAudioCaptured)`, its telemetry projection).
    #expect(KernelDictationDriver.endedWithoutSaveKind(for: .noTransport) == .failure)
  }

  @Test(".cancelled is excluded from the STATIC map (ambiguous — resolved dynamically)")
  func cancelledIsDynamic() {
    // `.cancelled` is reached by both a user cancel (delete) and a fault/system
    // cancel (retain), so the static map returns nil and the fire site resolves it
    // via the per-cancel disposition (Codex terminal-kind matrix).
    #expect(KernelDictationDriver.endedWithoutSaveKind(for: .cancelled) == nil)
  }

  @Test(".completed never fires the signal (durable save ran)")
  func completedIsNil() {
    #expect(KernelDictationDriver.endedWithoutSaveKind(for: .completed) == nil)
  }
}
