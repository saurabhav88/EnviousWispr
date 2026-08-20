import Foundation

// MARK: - FakeClock (epic #827, PR-2 plan §3.3)
//
// Deterministic logical clock. Advances ONLY on an explicit `advance(by:)` —
// never reads the wall clock, never sleeps. This is what makes wedge-detection
// and slow-warm-up scenarios reproducible without violating
// `~/.claude/rules/no-arbitrary-timeouts.md`: the simulator never sleeps on a
// real deadline, it advances logical ticks the scenario controls.
//
// `sleep(ticks:)` is the deterministic-async primitive: a caller suspends until
// the logical clock reaches its deadline. `advance(by:)` resumes every waiter
// whose deadline is now due. `drainPending()` resumes any straggler at scenario
// teardown so no `withCheckedContinuation` leaks.

@MainActor
final class FakeClock {
  /// Current logical tick count.
  private(set) var now: UInt64 = 0

  private struct Waiter {
    let deadline: UInt64
    let resume: () -> Void
  }

  private var waiters: [Waiter] = []

  /// Number of `advance(by:)`-driven ticks observed — lets a test prove the
  /// clock moved only on explicit advancement.
  private(set) var explicitAdvanceCount: Int = 0

  /// Waiters whose continuation has been RESUMED but whose task has not yet
  /// RUN — the signal `drainReadyWork` gates on so it cannot declare quiescence
  /// across that window (#1868).
  ///
  /// `continuation.resume()` makes a task READY, never running. `advance(by:)`
  /// removes a waiter from `waiters` BEFORE resuming it, so `hasPendingWaiters`
  /// goes false at exactly the wrong moment: the clock reports that nothing is
  /// waiting while a resumed sleeper has still not executed a line. Meanwhile
  /// the resume already bumped `kernel.workEpoch`, which the drain absorbs into
  /// its initial `last`, so epoch-stability offers no protection either. This
  /// counter is the one signal that stays true across the whole window.
  ///
  /// Incremented at BOTH resume sites and decremented by the resumed task
  /// itself, on the first line that runs after its `await`. `sleep(ticks:)`
  /// returns before appending for a non-positive `ticks`, so it can never
  /// decrement without a matching increment; every waiter is resumed exactly
  /// once because both sites remove before resuming; and the continuation is
  /// the non-throwing form, so no cancellation path skips the decrement.
  private(set) var unrunResumedWaiters: Int = 0

  init() {}

  /// Advance the logical clock by `ticks`, resuming every waiter whose deadline
  /// is reached. A non-positive `ticks` is a no-op.
  func advance(by ticks: Int) {
    guard ticks > 0 else { return }
    for _ in 0..<ticks {
      now += 1
      explicitAdvanceCount += 1
      let due = waiters.filter { $0.deadline <= now }
      waiters.removeAll { $0.deadline <= now }
      unrunResumedWaiters += due.count
      for waiter in due { waiter.resume() }
    }
  }

  /// Advance by exactly one tick.
  func tick() {
    advance(by: 1)
  }

  /// Suspend until the logical clock has advanced `ticks` from now. A
  /// non-positive `ticks` returns immediately.
  func sleep(ticks: Int) async {
    guard ticks > 0 else { return }
    let deadline = now + UInt64(ticks)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiters.append(Waiter(deadline: deadline) { continuation.resume() })
    }
    // First line that runs in the RESUMED task, which is what this counter
    // means — not the resume, which only made the task ready.
    unrunResumedWaiters -= 1
  }

  /// `true` while at least one caller is suspended in `sleep(ticks:)`.
  var hasPendingWaiters: Bool {
    !waiters.isEmpty
  }

  /// Resume every still-pending waiter without advancing the clock. Called by
  /// the runner at scenario teardown so a deliberately-wedged `sleep` does not
  /// leak its continuation.
  func drainPending() {
    let pending = waiters
    waiters.removeAll()
    unrunResumedWaiters += pending.count
    for waiter in pending { waiter.resume() }
  }
}
