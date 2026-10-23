import Foundation
import Testing

@testable import EnviousWisprCore

/// The shared "wait until it is observed" loop (#3986). When it is wrong, Paste Last Dictation
/// pastes after the user stopped expecting it or with their keys still held, and Quick Add copies
/// under a held shortcut or gives up on a press that was fine.
///
/// The clock is manual: each fake sleep advances it by a set step, so no test reads wall time.
@MainActor
@Suite(
  "Deadline poll: order of cancellation, deadline and condition (#3986)", .tags(.productOutcome))
struct DeadlinePollTests {

  @MainActor private final class Rig {
    let origin = ContinuousClock.now
    var elapsed: Duration = .zero
    /// How far each sleep moves the clock.
    var step: Duration = .milliseconds(10)
    /// The condition reads `true` from this read onward (1-based); nil means never.
    var trueFromRead: Int?
    var reads = 0
    var sleeps = 0
    /// When set, the sleep cancels the task it runs in, then returns.
    var cancelDuringSleep = false

    func now() -> ContinuousClock.Instant { origin + elapsed }
    // settle: not a wait; the fake advances the manual clock and returns at once
    func sleep(_ requested: Duration) async {
      sleeps += 1
      elapsed += step
      if cancelDuringSleep { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func condition() -> Bool {
      reads += 1
      guard let trueFromRead else { return false }
      return reads >= trueFromRead
    }
  }

  private func run(_ rig: Rig, within deadline: Duration) async -> DeadlinePoll.Result {
    await DeadlinePoll.wait(
      within: deadline, every: .milliseconds(10), now: rig.now, sleep: rig.sleep, rig.condition)
  }

  @Test("a condition already true is met on the first look, even with a zero deadline")
  func metOnFirstLook() async {
    let rig = Rig()
    rig.trueFromRead = 1
    #expect(await run(rig, within: .zero) == .met(elapsed: .zero))
    #expect(rig.reads == 1)
    #expect(rig.sleeps == 0)
  }

  @Test("a condition that becomes true after two sleeps is met with the elapsed time on the clock")
  func metAfterPolls() async {
    let rig = Rig()
    rig.trueFromRead = 3
    #expect(await run(rig, within: .milliseconds(100)) == .met(elapsed: .milliseconds(20)))
    #expect(rig.reads == 3)
    #expect(rig.sleeps == 2)
  }

  @Test("a condition never true expires, and the expiring poll does not read the condition")
  func expires() async {
    let rig = Rig()
    #expect(await run(rig, within: .milliseconds(50)) == .expired)
    // Reads at 0, 10, 20, 30, 40 ms; the poll that lands on 50 ms expires before reading.
    #expect(rig.reads == 5)
    #expect(rig.sleeps == 5)
  }

  @Test("a resume past the deadline expires even though the condition would now hold")
  func lateResumeExpires() async {
    let rig = Rig()
    rig.step = .milliseconds(200)
    rig.trueFromRead = 2
    #expect(await run(rig, within: .milliseconds(50)) == .expired)
    #expect(rig.reads == 1)
  }

  @Test("a task cancelled before entry is cancelled without reading the condition")
  func cancelledBeforeEntry() async {
    let rig = Rig()
    rig.trueFromRead = 1
    let task = Task { @MainActor in await self.run(rig, within: .milliseconds(50)) }
    task.cancel()
    #expect(await task.value == .cancelled)
    #expect(rig.reads == 0)
  }

  @Test("a task cancelled during a sleep is cancelled with no further read")
  func cancelledDuringSleep() async {
    let rig = Rig()
    rig.trueFromRead = 2
    rig.cancelDuringSleep = true
    let task = Task { @MainActor in await self.run(rig, within: .milliseconds(50)) }
    #expect(await task.value == .cancelled)
    #expect(rig.reads == 1)
    #expect(rig.sleeps == 1)
  }
}
