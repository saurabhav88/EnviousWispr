import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #1063 PR2 / #1548 D1 / #1464 — the driver projects each concluded session's
/// internal `RecordingOutcome` into the narrow public `RecordingRecoveryEnding`
/// that crosses into AppKit, where `RecoveryCoordinator` applies the sole
/// delete-versus-retain predicate. This suite freezes the PROJECTION (the family
/// mapping, payloads dropped); the delete/retain split is frozen separately in the
/// coordinator predicate tests. `matcher-set-adversarial-tests`: every outcome is
/// exercised, and `.completed` / `.cancelled` map to nil (a saved take never
/// fires; a cancel is resolved dynamically via `pendingCancelOrigin`).
@MainActor
@Suite("Kernel recovery-ending projection (#1063 PR2, #1548 D1, #1464)")
struct KernelTerminalKindTests {

  @Test("discard-family outcomes project to their narrow ending, payload dropped")
  func discardOutcomes() {
    #expect(
      KernelDictationDriver.recoveryEnding(for: .discarded(.tooShort)) == .discarded)
    #expect(
      KernelDictationDriver.recoveryEnding(for: .discarded(.releasedBeforeRecording))
        == .discarded)
    #expect(KernelDictationDriver.recoveryEnding(for: .noSpeech(.vadGate)) == .noSpeech)
    #expect(
      KernelDictationDriver.recoveryEnding(for: .noSpeech(.asrEmptyNoSpeech)) == .noSpeech)
  }

  @Test("fault-family outcomes project to their narrow ending, payload dropped")
  func failureOutcomes() {
    #expect(
      KernelDictationDriver.recoveryEnding(for: .failed(.asrFailed)) == .failed)
    #expect(
      KernelDictationDriver.recoveryEnding(for: .audioInterrupted(.engineLost))
        == .audioInterrupted)
    #expect(
      KernelDictationDriver.recoveryEnding(for: .audioInterrupted(nil)) == .audioInterrupted)
    #expect(
      KernelDictationDriver.recoveryEnding(for: .asrInterrupted(wasRecording: true))
        == .asrInterrupted)
    #expect(
      KernelDictationDriver.recoveryEnding(for: .asrInterrupted(wasRecording: false))
        == .asrInterrupted)
    #expect(KernelDictationDriver.recoveryEnding(for: .noTransport) == .noTransport)
  }

  @Test(".cancelled is excluded from the projection (resolved dynamically at the fire site)")
  func cancelledIsDynamic() {
    // `.cancelled` is reached by both a user cancel and a fault/system cancel, so
    // the static projection returns nil and the fire site injects the origin from
    // `pendingCancelOrigin` into `.cancelled(_)` (Codex terminal-kind matrix).
    #expect(KernelDictationDriver.recoveryEnding(for: .cancelled) == nil)
  }

  @Test(".completed never fires the signal (durable save ran)")
  func completedIsNil() {
    #expect(KernelDictationDriver.recoveryEnding(for: .completed) == nil)
  }
}
