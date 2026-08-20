import Foundation
import Testing

/// `FakeClock` behavior tests (epic #827, PR-2 plan §11.2 item C).
/// Proves the clock advances ONLY on explicit advancement and never reads the
/// wall clock — the property that makes the simulator deterministic.
@MainActor
@Suite("FakeClock")
struct FakeClockTests {

  @Test("starts at zero, advances only on explicit advance")
  func advancesOnlyExplicitly() {
    let clock = FakeClock()
    #expect(clock.now == 0)
    #expect(clock.explicitAdvanceCount == 0)
    clock.advance(by: 3)
    #expect(clock.now == 3)
    #expect(clock.explicitAdvanceCount == 3)
    clock.tick()
    #expect(clock.now == 4)
  }

  @Test("non-positive advance is a no-op")
  func nonPositiveAdvanceIsNoOp() {
    let clock = FakeClock()
    clock.advance(by: 0)
    clock.advance(by: -5)
    #expect(clock.now == 0)
  }

  @Test("sleep resumes exactly when the clock reaches the deadline")
  func sleepResumesAtDeadline() async {
    let clock = FakeClock()
    let woke = WokeFlag()
    let sleeper = Task { @MainActor in
      await clock.sleep(ticks: 3)
      woke.value = true
    }
    await clock.waitForRegistrations(1)
    clock.advance(by: 2)
    // Deliberately still a yield: this one proves a NEGATIVE (the sleeper must
    // NOT have woken), and no registration signal helps — there is no event to
    // park on when the correct behaviour is that nothing happens. A yield gives
    // the sleeper an opportunity it must decline. Weaker than the rest of this
    // suite and knowingly so; binding it needs a "deadline not yet reached"
    // signal the clock does not have.
    await Task.yield()
    #expect(woke.value == false, "sleeper must not wake before its deadline")
    clock.advance(by: 1)
    await sleeper.value
    #expect(woke.value == true)
  }

  @Test("sleep of non-positive ticks returns immediately")
  func sleepZeroReturnsImmediately() async {
    let clock = FakeClock()
    await clock.sleep(ticks: 0)
    #expect(clock.hasPendingWaiters == false)
  }

  @Test("drainPending resumes a straggler without advancing the clock")
  func drainPendingResumesStraggler() async {
    let clock = FakeClock()
    let woke = WokeFlag()
    let sleeper = Task { @MainActor in
      await clock.sleep(ticks: 100)
      woke.value = true
    }
    await clock.waitForRegistrations(1)
    #expect(clock.hasPendingWaiters == true)
    clock.drainPending()
    await sleeper.value
    #expect(woke.value == true)
    #expect(clock.now == 0, "drainPending must not advance the clock")
  }

  // MARK: - #1868: resumed-but-not-yet-run waiters

  /// The whole point of `unrunResumedWaiters`, and the reason no existing signal
  /// covers this window: `advance(by:)` REMOVES a waiter from `waiters` before
  /// resuming it, so `hasPendingWaiters` is already false while the sleeper has
  /// not executed a line. A drain consulting only that signal would declare
  /// quiescence mid-handoff.
  ///
  /// That is a real window and this suite is the only thing that observes it —
  /// no drain consults this counter. It is deliberately NOT the #1868 flake,
  /// which an earlier version of this comment claimed: A13 loses its terminal
  /// between `spawn` and the sleep REGISTERING, where this counter reads zero.
  @Test("a resumed sleeper is still outstanding until its task actually runs")
  func resumedWaiterIsOutstandingUntilItRuns() async {
    let clock = FakeClock()
    let woke = WokeFlag()
    let sleeper = Task { @MainActor in
      await clock.sleep(ticks: 1)
      woke.value = true
    }
    // Park on the clock's own REGISTRATION signal, never on a yield count: a
    // yield assumes one hop is enough for the sleeper to reach its suspension
    // point, and under contention `advance(by:)` would then see no waiter,
    // resume nothing, and leave the sleeper suspended forever. Cloud review
    // caught that guess in this very suite (PR #2233) — the defect #2143 names,
    // committed inside the tests fixing it.
    await clock.waitForRegistrations(1)
    #expect(clock.unrunResumedWaiters == 0, "nothing has been resumed yet")

    clock.advance(by: 1)
    // The resume made the task READY, not running. This is the window.
    #expect(
      clock.hasPendingWaiters == false,
      "control: the old signal has already gone false here, which is the defect")
    #expect(woke.value == false, "control: the sleeper has not run yet")
    #expect(
      clock.unrunResumedWaiters == 1,
      "a resumed-but-unrun sleeper must still be outstanding")

    await sleeper.value
    #expect(woke.value == true)
    #expect(clock.unrunResumedWaiters == 0, "the resumed task cleared it by running")
  }

  @Test("drainPending's resumes are outstanding until their tasks run")
  func drainPendingResumesAreOutstanding() async {
    let clock = FakeClock()
    let sleeper = Task { @MainActor in await clock.sleep(ticks: 100) }
    await clock.waitForRegistrations(1)
    clock.drainPending()
    #expect(
      clock.unrunResumedWaiters == 1,
      "drainPending resumes too, so it must count the same way advance does")
    await sleeper.value
    #expect(clock.unrunResumedWaiters == 0)
  }

  /// The counter must never go negative, or a drain gated on `== 0` could return
  /// while work is outstanding. `sleep` returns BEFORE appending a waiter for a
  /// non-positive tick count, so it must not decrement either.
  @Test("a non-positive sleep neither increments nor decrements the counter")
  func nonPositiveSleepIsBalanced() async {
    let clock = FakeClock()
    await clock.sleep(ticks: 0)
    await clock.sleep(ticks: -5)
    #expect(clock.unrunResumedWaiters == 0)
  }

  @Test("many waiters resumed by one advance are all counted")
  func manyWaitersAreAllCounted() async {
    let clock = FakeClock()
    let sleepers = (0..<3).map { _ in Task { @MainActor in await clock.sleep(ticks: 1) } }
    await clock.waitForRegistrations(3)
    clock.advance(by: 1)
    #expect(clock.unrunResumedWaiters == 3)
    for s in sleepers { await s.value }
    #expect(clock.unrunResumedWaiters == 0)
  }

  @MainActor
  final class WokeFlag {
    var value = false
  }
}
