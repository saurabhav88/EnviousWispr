/// Atomic mutual-exclusion primitive between crash-recovery replay and every
/// OTHER engine-mutating operation (#1707 Phase 3).
///
/// The pre-existing `EngineCoordinator.isSwitching`/`RecoveryCoordinator`
/// contention guard already gives full-duration mutual exclusion between
/// recovery and an engine SWITCH specifically (`isSwitching` is held across
/// the entire awaited switch). Nothing gave that same full-duration guarantee
/// to every OTHER engine-mutating actor — warm-ups, unloads, downloads,
/// migrations, benchmarks — until now. A point-in-time boolean recheck
/// immediately before an `await` is a check-then-act race, not a true
/// exclusion (governing Bible `RULE: engine-readiness-is-an-atomic-claim-not-a-predicate`);
/// this type is the corrected shape: a claim held for the FULL duration of the
/// operation, checked and acquired in a single non-suspending MainActor turn.
///
/// `mutationCount` intentionally allows multiple non-recovery mutations to
/// overlap exactly as they can today — its sole contract is that recovery
/// cannot begin until every held mutation claim has released, and no mutation
/// can begin while recovery holds the engine.
///
/// This is NOT a scheduler or wake registry: it has exactly two operation
/// pairs and no scheduling logic of its own. `RecoveryCoordinator` still
/// decides WHEN to scan and WHAT to retry; this only answers "is it safe to
/// touch the engine right now."
///
/// Owned as a `let` by `WisprBootstrapper` (the composition root) and
/// injected downward as narrow closures — `EnviousWisprPipeline` and
/// `EnviousWisprASR` cannot import this `AppKit`-level type upward.
@MainActor
final class EngineRecoveryGate {
  private(set) var isRecoveryClaimed = false
  private var mutationCount = 0
  private var recoveryRetryOwed = false

  /// Attempts to claim the engine for a crash-recovery replay item. Fails
  /// while ANY mutation claim is held or recovery already holds the claim.
  /// On failure while a mutation is in flight, records that recovery is owed
  /// a wake-up so it is never stranded once the last mutation releases.
  func tryBeginRecovery() -> Bool {
    guard !isRecoveryClaimed, mutationCount == 0 else {
      if mutationCount > 0 { recoveryRetryOwed = true }
      return false
    }
    isRecoveryClaimed = true
    return true
  }

  func endRecovery() {
    precondition(isRecoveryClaimed)
    isRecoveryClaimed = false
  }

  /// Attempts to claim the engine for a non-switch engine mutation (warm-up,
  /// unload, download, migration, benchmark). Fails while recovery holds the
  /// claim; every caller must handle `false` by deferring/aborting its
  /// mutation, never by proceeding anyway.
  func tryBeginMutation() -> Bool {
    guard !isRecoveryClaimed else { return false }
    mutationCount += 1
    return true
  }

  /// Returns true exactly when this was the LAST held mutation claim AND a
  /// recovery attempt was refused while mutations were in flight — the
  /// caller must invoke its recovery-recheck wake-up when this returns true,
  /// so a denied recovery claim is never stranded without a guaranteed
  /// wake-up.
  func endMutation() -> Bool {
    precondition(mutationCount > 0)
    mutationCount -= 1
    guard mutationCount == 0, recoveryRetryOwed else { return false }
    recoveryRetryOwed = false
    return true
  }
}
