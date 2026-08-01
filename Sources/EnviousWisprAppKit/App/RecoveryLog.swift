import EnviousWisprCore
import os

/// #1762 — the ONE place recovery writes to the local debug log.
///
/// Recovery emitted nothing to `app.log`: neither `RecoveryCoordinator` nor
/// `RecoverySpoolReplayer` carried a single line, so on a real machine a
/// replay-and-delete of an orphan that produced no text looked exactly like
/// "recovery is broken". That cost an hour of live diagnosis and one falsely
/// filed bug (#1760), and it is why #1813's cause had to be inferred from
/// aggregate telemetry across 50 users instead of reproduced on one.
///
/// ## Ordering is carried in the LINE, never in the scheduling
///
/// This went through three shapes. Fire-and-forget `Task`s reorder, so the
/// missing-outcome wedge signature could read backwards. Making the call
/// `async` fixed that and introduced something far worse: an `await` inside the
/// coordinator's per-item critical section, where `isRecovering` and
/// `activeRecoveryID` are still set. A Discard landing in that suspension
/// deletes a recording the outcome said to KEEP. A diagnostic must never widen
/// a window in the code it observes.
///
/// So emission stays non-suspending, and every line carries a monotonic
/// sequence number instead. A reader sorts by `#N` and gets true call order
/// even when the writes interleave — the wedge signature (an `attempting`
/// with no later outcome) survives, and no critical section grows an await.
///
/// **Never pass transcript text, spool bytes, key material, or a device
/// identifier.** Counts, outcomes, durations and closed-vocabulary labels only —
/// the same content-free rule the telemetry boundary follows. A recovered
/// transcript is described by its character count and nothing else.
///
/// Release builds do nothing: the body compiles out rather than relying on
/// `AppLogger.log` being internally `#if DEBUG`.
enum RecoveryLog {
  #if DEBUG
    /// Assigned at CALL time, not at write time, so the number reflects the
    /// order the code reached each line rather than the order tasks drained.
    private static let sequence = OSAllocatedUnfairLock(initialState: 0)
  #endif

  static func line(_ message: String) {
    #if DEBUG
      let n = sequence.withLock { value -> Int in
        value += 1
        return value
      }
      Task { await AppLogger.shared.log("#\(n) \(message)", level: .info, category: "Recovery") }
    #endif
  }
}
