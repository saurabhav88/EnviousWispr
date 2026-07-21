import Testing

@testable import EnviousWisprAppKit

/// #1707 Phase 3 (§3.2) — the atomic mutual-exclusion primitive between
/// crash-recovery replay and every OTHER engine-mutating operation. Exclusion,
/// not preemption: once a mutation has ALREADY acquired its claim, a recovery
/// attempt starting after that must be REFUSED, never must it preempt the
/// already-running mutation.
@MainActor
@Suite("EngineRecoveryGate (#1707 Phase 3)")
struct EngineRecoveryGateTests {

  @Test("recovery claims freely when nothing is mutating")
  func recoveryClaimsWhenIdle() {
    let gate = EngineRecoveryGate()
    #expect(gate.tryBeginRecovery())
    #expect(gate.isRecoveryClaimed)
    gate.endRecovery()
    #expect(!gate.isRecoveryClaimed)
  }

  @Test("mutation claims freely when nothing is recovering")
  func mutationClaimsWhenIdle() {
    let gate = EngineRecoveryGate()
    #expect(gate.tryBeginMutation())
    #expect(gate.endMutation() == false, "no recovery was ever denied — no wake-up owed")
  }

  @Test("a held mutation refuses recovery for its FULL duration, then recovery wakes and acquires")
  func mutationExcludesRecoveryForFullDuration() {
    let gate = EngineRecoveryGate()
    #expect(gate.tryBeginMutation())
    // Recovery's attempt FAILS while the mutation remains active — exclusion,
    // not preemption of the already-running mutation.
    #expect(!gate.tryBeginRecovery())
    #expect(!gate.tryBeginRecovery(), "still refused — the mutation is still held")
    // The mutation releases; it was the last held claim AND recovery was
    // denied while it was in flight, so the caller is told to wake recovery.
    #expect(gate.endMutation() == true)
    // Recovery now acquires successfully.
    #expect(gate.tryBeginRecovery())
    gate.endRecovery()
  }

  @Test("a held recovery claim refuses every mutation for its FULL duration")
  func recoveryExcludesMutationForFullDuration() {
    let gate = EngineRecoveryGate()
    #expect(gate.tryBeginRecovery())
    #expect(!gate.tryBeginMutation())
    #expect(!gate.tryBeginMutation(), "still refused — recovery is still held")
    gate.endRecovery()
    #expect(gate.tryBeginMutation())
  }

  @Test(
    "two simultaneous mutation claims: recovery stays refused until BOTH release, wakes exactly once"
  )
  func twoOverlappingMutationsBothMustReleaseBeforeRecoveryWakes() {
    let gate = EngineRecoveryGate()
    #expect(gate.tryBeginMutation(), "first mutation claim")
    #expect(gate.tryBeginMutation(), "second, overlapping mutation claim")
    #expect(!gate.tryBeginRecovery(), "denied while EITHER mutation is held")
    // The first release does NOT drain mutationCount to zero — no wake-up yet.
    #expect(gate.endMutation() == false, "one claim remains — not yet owed")
    #expect(!gate.tryBeginRecovery(), "still refused — the second claim is still held")
    // The second (and last) release drains mutationCount to zero — wake-up owed.
    #expect(gate.endMutation() == true)
    #expect(gate.tryBeginRecovery())
    gate.endRecovery()
  }

  @Test("two separate recovery-claim attempts denied by one mutation both set the SAME wake-up")
  func twoSimultaneousDenialsCoalesceIntoOneWakeUp() {
    let gate = EngineRecoveryGate()
    #expect(gate.tryBeginMutation())
    #expect(!gate.tryBeginRecovery(), "first denial")
    #expect(!gate.tryBeginRecovery(), "second denial — recoveryRetryOwed must not be lost")
    // Exactly one wake-up fires on the single mutation's release — a rescan
    // re-discovers every spool from disk, so coalescing to one is correct,
    // not a lost second denial.
    #expect(gate.endMutation() == true)
    #expect(gate.tryBeginRecovery())
    gate.endRecovery()
  }

  @Test("a mutation denied while recovery is claimed grants no wake-up on recovery's own release")
  func recoveryReleaseNeverOwesAMutationWakeUp() {
    let gate = EngineRecoveryGate()
    #expect(gate.tryBeginRecovery())
    #expect(!gate.tryBeginMutation(), "denied while recovery holds the claim")
    gate.endRecovery()
    // `endRecovery()` returns Void by design — mutation call sites rely on
    // their OWN natural retry trigger (a future press, a future timer), not a
    // gate-driven wake-up, per §3.2's documented design choice.
    #expect(gate.tryBeginMutation())
  }

  @Test("mutationCount allows unrelated mutations to overlap exactly as they can today")
  func mutationsOverlapFreely() {
    let gate = EngineRecoveryGate()
    #expect(gate.tryBeginMutation())
    #expect(gate.tryBeginMutation())
    #expect(gate.tryBeginMutation())
    #expect(gate.endMutation() == false)
    #expect(gate.endMutation() == false)
    #expect(gate.endMutation() == false, "no recovery was ever denied across any of these")
  }
}
