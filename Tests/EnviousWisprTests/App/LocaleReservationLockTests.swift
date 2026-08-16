import Foundation
import Testing

@testable import EnviousWisprLivePreview

/// #2080 round 5 — the reservation transaction must not interleave.
///
/// Two callers share it: a recording claiming the language it is about to transcribe, and the
/// settings page claiming one it is about to download. The transaction reads the current claims,
/// maybe evicts the oldest, then reserves — suspending at each step. Interleaved, both can act on
/// the same five-slot reading, and whoever loses fails silently.
///
/// **These test the exclusion, not Apple.** The inventory is static and uninjectable, so the
/// testable core is the primitive: does the critical section stay exclusive ACROSS suspensions.
/// That is precisely what an actor alone would fail to give, so it is the property worth pinning.
struct LocaleReservationLockTests {

  /// Counts how many tasks are inside the critical section at once, and remembers the worst case.
  private actor Occupancy {
    private(set) var inside = 0
    private(set) var peak = 0
    private(set) var completed = 0

    func enter() {
      inside += 1
      peak = max(peak, inside)
    }
    func leave() {
      inside -= 1
      completed += 1
    }
  }

  @Test("Only one caller is inside the reservation transaction at a time")
  func lockExcludesAcrossSuspensions() async {
    // Its own instance, not `shared`: tests in a suite run in parallel, so measuring the
    // singleton would mean two tests contending for the very thing under measurement.
    let lock = LocaleReservationLock()
    let occupancy = Occupancy()

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<12 {
        group.addTask {
          await lock.acquire()
          await occupancy.enter()
          // Suspend INSIDE the section, which is what the real transaction does three times over.
          // An actor-only guard would let a sibling in right here; a held lock must not.
          await Task.yield()
          await Task.yield()
          await occupancy.leave()
          await lock.release()
        }
      }
    }

    let peak = await occupancy.peak
    let completed = await occupancy.completed
    #expect(completed == 12, "control: every task ran, so the peak below means something")
    #expect(
      peak == 1,
      "\(peak) callers were inside the reservation transaction at once; it must be exclusive")
  }

  /// Ownership passes straight from `release()` to the next waiter, so the lock is reusable and
  /// nobody is stranded. A hand-off that cleared `held` first would leave a gap; a hand-off that
  /// forgot to resume would deadlock, and this test would hang rather than fail — which is why
  /// the count above is asserted too.
  @Test("The lock is reusable and every waiter is eventually served")
  func lockHandsOffToEveryWaiter() async {
    // Its own instance, not `shared`: tests in a suite run in parallel, so measuring the
    // singleton would mean two tests contending for the very thing under measurement.
    let lock = LocaleReservationLock()
    let occupancy = Occupancy()

    for _ in 0..<3 {
      await lock.acquire()
      await occupancy.enter()
      await occupancy.leave()
      await lock.release()
    }

    #expect(await occupancy.completed == 3, "a released lock must be acquirable again")
    #expect(await occupancy.inside == 0, "and must not be left held")
  }
}
