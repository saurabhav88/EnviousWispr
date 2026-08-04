import Foundation
import os

/// Arbitrates the single 100 ms deadline that now covers BOTH language
/// resolution and cursor-insertion repair (#1921).
///
/// Before #1921 only repair sat inside `withOrderedDeadline`; language
/// resolution ran ahead of it, unbounded, on the paste path. Moving resolution
/// inside the same deadline creates a question the old code never had to answer:
/// **which stage timed out?** It matters because the existing `onTimeout`
/// permanently disables `EnglishWordOracleRuntime`, and doing that because the
/// LANGUAGE stage stalled would kill an unrelated, healthy component for the
/// rest of the process.
///
/// A plain "did the repair stage begin" flag is not enough, and this is the
/// whole reason a lock exists here. `withOrderedDeadline` cancels
/// best-effort — its own comment says cancellation "cannot preempt a blocked
/// thread" (`TaskTimeout.swift:129`) — and `onTimeout()` runs synchronously
/// before the nil resume. So with a flag, the timeout can observe "still
/// resolving", decline to disable, and the un-preempted operation can then walk
/// straight into the oracle anyway.
///
/// Four states rather than three, which grounded review r3 found: `TaskTimeout`
/// runs `await operation()` and its `claim()` as separate steps
/// (`TaskTimeout.swift:123-125`), so repair can FINISH and the timeout can still
/// win `claim()` in the gap. A three-state gate reads that as still-running,
/// concludes the oracle is stuck, and disables a component that had just
/// succeeded. `completed` is that gap.
///
/// **One lock, not two (integration review round 2).** An earlier version of
/// this type kept `oracleTouched` in a SECOND `OSAllocatedUnfairLock`, read just
/// before the phase lock was claimed. That is check-then-act: between the read
/// and the claim, repair can consult the oracle and block, and the timeout then
/// claims with a stale `false` and leaves a genuinely stuck oracle enabled.
/// Merging the flag into the phase makes the two facts one atomic transition,
/// and it is simpler than what it replaced. Every mutation below is exactly one
/// `withLock`, so neither side can lose a window.
package final class LanguageRepairDeadlineGate: Sendable {

  private enum Phase: Sendable {
    /// Resolution in flight. Repair has not been authorised.
    case resolvingLanguage
    /// Repair genuinely running, carrying whether the word oracle has actually
    /// been consulted yet. This is the only phase that may disable the oracle,
    /// and only with `oracleTouched` true.
    case repair(DictationLanguageResolver.Resolution, oracleTouched: Bool)
    /// Repair returned; the operation has not claimed its result yet.
    case completed(DictationLanguageResolver.Resolution)
    /// Terminal.
    case timedOut
  }

  private let phase = OSAllocatedUnfairLock(initialState: Phase.resolvingLanguage)

  package init() {}

  /// Authorises repair, carrying the resolution the timeout would otherwise lose.
  ///
  /// Returns `false` when the deadline already claimed the phase, which is the
  /// signal for the operation to return the legacy payload WITHOUT calling
  /// repair. That is the guarantee a cancellation flag cannot give, because the
  /// operation may not have been preempted at all.
  package func beginRepair(_ resolution: DictationLanguageResolver.Resolution) -> Bool {
    phase.withLock {
      guard case .resolvingLanguage = $0 else { return false }
      $0 = .repair(resolution, oracleTouched: false)
      return true
    }
  }

  /// May the word oracle be consulted right now, and record that it was.
  ///
  /// Called from the oracle's own closures on EVERY consultation, not merely the
  /// first — which is what makes it a guard rather than a notification. Two
  /// jobs, and they must be one transition:
  ///
  /// 1. **Record** that the oracle was genuinely reached. `beginRepair` runs
  ///    before `CursorInsertionRepair.repair`, but repair has early exits and
  ///    does all its spacing work before it ever consults word knowledge. Arming
  ///    on "repair began" lets a timeout in that window permanently disable an
  ///    oracle that was never touched — the exact harm this gate exists to
  ///    prevent, moved one step later rather than removed.
  /// 2. **Refuse** once the deadline has fired. Cancellation cannot preempt a
  ///    blocked thread, so without this an un-preempted repair walks into the
  ///    real oracle AFTER the timeout already gave up — the unbounded blocking
  ///    call the deadline exists to bound. The wrapper's refusal keeps the
  ///    capital, so a late refusal can only be safe.
  ///
  /// Idempotent; the cost is one uncontended lock per word decision.
  package func authorizeOracleUse() -> Bool {
    phase.withLock {
      guard case .repair(let resolution, _) = $0 else { return false }
      $0 = .repair(resolution, oracleTouched: true)
      return true
    }
  }

  /// Marks repair finished. Must be called immediately after repair returns and
  /// before the deadline operation's closure returns, so the window in which a
  /// healthy oracle looks stuck is as small as the runtime allows.
  ///
  /// Inert from any other phase: a `completeRepair` that never began must not
  /// promote `resolvingLanguage` into a completed run.
  package func completeRepair() {
    phase.withLock {
      guard case .repair(let resolution, _) = $0 else { return }
      $0 = .completed(resolution)
    }
  }

  /// Claims the phase for the deadline and reports what the caller may do.
  ///
  /// - Returns: the resolution when one was reached, so an oracle-stage or
  ///   post-repair timeout still reports its real source and confidence rather
  ///   than `none` / `none`; and whether the oracle runtime may be disabled,
  ///   which is true ONLY for an oracle that was genuinely consulted.
  package func timeOut()
    -> (resolution: DictationLanguageResolver.Resolution?, shouldDisableOracle: Bool)
  {
    phase.withLock {
      let result: (DictationLanguageResolver.Resolution?, Bool) =
        switch $0 {
        // Nothing ran. Nothing to report, nothing to punish.
        case .resolvingLanguage: (nil, false)
        // Repair is still running. Disable ONLY if the oracle was genuinely
        // consulted — repair may have stalled in its own spacing work, or have
        // taken an early exit, without ever reaching it.
        case .repair(let resolution, let oracleTouched): (resolution, oracleTouched)
        // Repair already returned, so whatever it consulted answered in time.
        case .completed(let resolution): (resolution, false)
        case .timedOut: (nil, false)
        }
      $0 = .timedOut
      return result
    }
  }
}
