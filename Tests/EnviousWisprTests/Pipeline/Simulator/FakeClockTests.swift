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
    await Task.yield()
    clock.advance(by: 2)
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
    await Task.yield()
    #expect(clock.hasPendingWaiters == true)
    clock.drainPending()
    await sleeper.value
    #expect(woke.value == true)
    #expect(clock.now == 0, "drainPending must not advance the clock")
  }

  @MainActor
  final class WokeFlag {
    var value = false
  }
}
