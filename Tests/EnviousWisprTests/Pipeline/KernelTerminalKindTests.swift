import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
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

  @Test(
    "#1707 Phase 2: a .failed outcome whose retry was exhausted projects to .asrRetryExhausted, distinct from plain .failed"
  )
  func exhaustedRetryProjectsToDistinctEnding() {
    #expect(
      KernelDictationDriver.recoveryEnding(for: .failed(.asrFailed), retryOutcome: .retryExhausted)
        == .asrRetryExhausted)
  }

  @Test(
    "#1707 Phase 2: a .failed outcome projects to plain .failed when the retry was never consulted, only attempted, or succeeded"
  )
  func nonExhaustedRetryOutcomesProjectToPlainFailed() {
    // Pre-capture producer — retry never consulted at all (the default,
    // matching every existing call site above).
    #expect(
      KernelDictationDriver.recoveryEnding(for: .failed(.asrFailed), retryOutcome: nil) == .failed)
    // A retry preempted mid-flight by a competing interruption before its own
    // result was ever accepted (§3a) — still plain .failed, never the
    // exhausted-specific ending (this session's OWN retry never resolved to
    // exhausted).
    #expect(
      KernelDictationDriver.recoveryEnding(for: .failed(.asrFailed), retryOutcome: .attempted)
        == .failed)
    // A retry that actually succeeded reaches `.completed`, not `.failed`, in
    // production — but the projection itself is exhaustive over
    // `ASRRetryOutcome?` and must not accidentally map this combination to
    // the exhausted ending either.
    #expect(
      KernelDictationDriver.recoveryEnding(for: .failed(.asrFailed), retryOutcome: .retrySucceeded)
        == .failed)
  }

  @Test(
    "#1707 Codex r7: an .asrInterrupted outcome whose retry was exhausted ALSO projects to .asrRetryExhausted, since interruptedTerminalFloor can raise an exhausted-retry .failed into .asrInterrupted"
  )
  func exhaustedRetryAfterInterruptionFloorProjectsToDistinctEnding() {
    #expect(
      KernelDictationDriver.recoveryEnding(
        for: .asrInterrupted(wasRecording: true), retryOutcome: .retryExhausted)
        == .asrRetryExhausted)
    #expect(
      KernelDictationDriver.recoveryEnding(
        for: .asrInterrupted(wasRecording: false), retryOutcome: .retryExhausted)
        == .asrRetryExhausted)
  }

  @Test(
    "#1707 Codex r7: an .asrInterrupted outcome projects to plain .asrInterrupted when the retry was never consulted, only attempted, or succeeded"
  )
  func nonExhaustedRetryOutcomesProjectToPlainAsrInterrupted() {
    #expect(
      KernelDictationDriver.recoveryEnding(
        for: .asrInterrupted(wasRecording: true), retryOutcome: nil)
        == .asrInterrupted)
    #expect(
      KernelDictationDriver.recoveryEnding(
        for: .asrInterrupted(wasRecording: true), retryOutcome: .attempted)
        == .asrInterrupted)
    #expect(
      KernelDictationDriver.recoveryEnding(
        for: .asrInterrupted(wasRecording: true), retryOutcome: .retrySucceeded)
        == .asrInterrupted)
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

// MARK: - #1755 chunk 5 — ending × retry-outcome composed through both real authorities

/// Proves the existing projection collapse is CORRECT under the discard
/// doctrine: every retry-outcome cell of `.failed(.asrFailed)` and both
/// `.asrInterrupted` payloads project to an ending the coordinator deletes.
@MainActor
@Suite("Ending × retry-outcome composed matrix (#1755)")
struct EndingRetryOutcomeComposedMatrixTests {
  private func composedDelete(
    _ outcome: RecordingOutcome, _ retry: ASRRetryOutcome?
  ) -> (ending: RecordingRecoveryEnding?, deletes: Bool) {
    let ending = KernelDictationDriver.recoveryEnding(for: outcome, retryOutcome: retry)
    guard let ending else { return (nil, false) }
    return (ending, RecoveryCoordinator.shouldDeleteOnLiveEnding(ending))
  }

  @Test(".failed(.asrFailed): all four retry-outcome cells project and delete")
  func failedAllRetryCellsDelete() {
    #expect(composedDelete(.failed(.asrFailed), nil) == (.failed, true))
    #expect(composedDelete(.failed(.asrFailed), .attempted) == (.failed, true))
    #expect(composedDelete(.failed(.asrFailed), .retrySucceeded) == (.failed, true))
    #expect(composedDelete(.failed(.asrFailed), .retryExhausted) == (.asrRetryExhausted, true))
  }

  @Test(".asrInterrupted (both payloads): all four retry-outcome cells project and delete")
  func asrInterruptedAllRetryCellsDelete() {
    for wasRecording in [true, false] {
      let outcome = RecordingOutcome.asrInterrupted(wasRecording: wasRecording)
      #expect(composedDelete(outcome, nil) == (.asrInterrupted, true))
      #expect(composedDelete(outcome, .attempted) == (.asrInterrupted, true))
      #expect(composedDelete(outcome, .retrySucceeded) == (.asrInterrupted, true))
      #expect(composedDelete(outcome, .retryExhausted) == (.asrRetryExhausted, true))
    }
  }

  @Test("characterization: .completed and static .cancelled stay outside the predicate")
  func completedAndStaticCancelledProjectNil() {
    #expect(KernelDictationDriver.recoveryEnding(for: .completed) == nil)
    #expect(KernelDictationDriver.recoveryEnding(for: .cancelled) == nil)
    // Both DYNAMIC cancel origins delete when presented to the coordinator.
    #expect(RecoveryCoordinator.shouldDeleteOnLiveEnding(.cancelled(.user)))
    #expect(RecoveryCoordinator.shouldDeleteOnLiveEnding(.cancelled(.systemOrFault)))
    // No-ending/app-gone has no predicate invocation by construction — there
    // is no synthetic ending to test, which is the point.
  }
}
