import AppKit
import Testing

@testable import EnviousWisprAppKit

/// `OverlayFirstRenderGate` in isolation — no `OverlayDirector` involved.
/// The Director's own use of this type is proved separately, in its own
/// integration suite; this suite exists so the coalescing property holds
/// even before there is a Director to coalesce FOR.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayFirstRenderGateTests {

  /// A one-slot manual scheduler: `schedule` captures the work instead of
  /// running it, so the test controls exactly when the gate's "next turn"
  /// fires — the same seam production uses `DispatchQueue.main.async` for.
  final class ManualScheduler {
    private(set) var queued: [() -> Void] = []

    func schedule(_ work: @escaping () -> Void) {
      queued.append(work)
    }

    func fireAll() {
      let work = queued
      queued.removeAll()
      for item in work { item() }
    }
  }

  @Test("many pre-ready calls schedule exactly once")
  func repeatedSchedulingEnqueuesOnce() {
    let scheduler = ManualScheduler()
    var constructionCount = 0

    let gate = OverlayFirstRenderGate(
      schedule: scheduler.schedule,
      construct: {
        constructionCount += 1
        return NSView()
      },
      didBecomeReady: { _ in })

    gate.scheduleIfNeeded()
    gate.scheduleIfNeeded()
    gate.scheduleIfNeeded()

    #expect(scheduler.queued.count == 1, "three calls before readiness must enqueue one block")
    #expect(constructionCount == 0, "construction has not run until the scheduled block fires")

    scheduler.fireAll()

    #expect(constructionCount == 1, "the scheduled block constructs exactly once")
  }

  @Test("readyRoot is nil before construction and the SAME instance after")
  func readyRootPublishesOnce() {
    let scheduler = ManualScheduler()
    let constructed = NSView()

    let gate = OverlayFirstRenderGate(
      schedule: scheduler.schedule,
      construct: { constructed },
      didBecomeReady: { _ in })

    #expect(gate.readyRoot == nil, "no construction has happened yet")

    gate.scheduleIfNeeded()
    #expect(gate.readyRoot == nil, "scheduled, not yet built")

    scheduler.fireAll()
    #expect(gate.readyRoot === constructed, "the exact constructed instance, not a copy")
  }

  @Test("didBecomeReady fires exactly once, with the constructed root")
  func readinessCallbackFiresOnce() {
    let scheduler = ManualScheduler()
    let constructed = NSView()
    var readyCallCount = 0
    var receivedRoot: NSView?

    let gate = OverlayFirstRenderGate(
      schedule: scheduler.schedule,
      construct: { constructed },
      didBecomeReady: { root in
        readyCallCount += 1
        receivedRoot = root
      })

    gate.scheduleIfNeeded()
    gate.scheduleIfNeeded()
    scheduler.fireAll()

    #expect(readyCallCount == 1)
    #expect(receivedRoot === constructed)

    // TWIN: scheduling again once ready is a no-op — this is what lets the
    // Director call `scheduleIfNeeded()` unconditionally on every pre-ready
    // presentation without worrying whether it already fired.
    gate.scheduleIfNeeded()
    #expect(scheduler.queued.isEmpty, "already ready — nothing new to schedule")
    #expect(readyCallCount == 1, "readiness does not fire again")
  }

  @Test("state is scheduled before an immediate scheduler can re-enter")
  func immediateSchedulerCannotReenterAndDoubleBuild() {
    // The load-bearing property the type's own doc comment states: setting
    // `.scheduled` BEFORE invoking `schedule` means a reentrant call arriving
    // WHILE the scheduler closure is still running its first invocation
    // — before `work()` has ever executed, so state has had no chance to
    // reach `.ready` — is already a no-op.
    var scheduleCallCount = 0
    var constructionCount = 0
    var gate: OverlayFirstRenderGate!

    gate = OverlayFirstRenderGate(
      schedule: { work in
        scheduleCallCount += 1
        if scheduleCallCount == 1 {
          gate.scheduleIfNeeded()
          work()
        }
      },
      construct: {
        constructionCount += 1
        return NSView()
      },
      didBecomeReady: { _ in })

    gate.scheduleIfNeeded()

    #expect(scheduleCallCount == 1, "the reentrant call must not enqueue a second block")
    #expect(
      constructionCount == 1, "reentrant scheduling during construction must not double-build")
  }

  // MARK: - scheduleIfNeeded(using:) override (#2377 Phase 6 C4)

  @Test("a per-call scheduler override is used instead of the constructor's default")
  func overrideSchedulerIsUsedWhenSupplied() {
    let defaultScheduler = ManualScheduler()
    let overrideScheduler = ManualScheduler()
    var constructionCount = 0

    let gate = OverlayFirstRenderGate(
      schedule: defaultScheduler.schedule,
      construct: {
        constructionCount += 1
        return NSView()
      },
      didBecomeReady: { _ in })

    gate.scheduleIfNeeded(using: overrideScheduler.schedule)

    #expect(defaultScheduler.queued.isEmpty, "the default scheduler must not be invoked")
    #expect(overrideScheduler.queued.count == 1, "the override scheduler receives the work")

    overrideScheduler.fireAll()
    #expect(constructionCount == 1, "the override scheduler's fire constructs exactly once")
  }

  @Test("omitting the override preserves the exact prior default-scheduler behavior")
  func noOverridePreservesTheDefaultScheduler() {
    // TWIN of the override test: production's existing demand-driven call
    // sites pass no argument at all, and this proves that call shape still
    // reaches the constructor's own `schedule` unchanged — the default
    // parameter must not silently redirect every caller.
    let defaultScheduler = ManualScheduler()
    var constructionCount = 0

    let gate = OverlayFirstRenderGate(
      schedule: defaultScheduler.schedule,
      construct: {
        constructionCount += 1
        return NSView()
      },
      didBecomeReady: { _ in })

    gate.scheduleIfNeeded()

    #expect(defaultScheduler.queued.count == 1, "the bare call reaches the default scheduler")
    defaultScheduler.fireAll()
    #expect(constructionCount == 1)
  }

  @Test("demand-driven scheduling first makes a later prewarm call a no-op")
  func demandDrivenFirstMakesPrewarmANoOp() {
    // Race direction 1 (plan §5/§7): the default scheduler wins, the
    // override scheduler never receives anything, and construction still
    // happens exactly once via the WINNING scheduler's fire.
    let defaultScheduler = ManualScheduler()
    let overrideScheduler = ManualScheduler()
    var constructionCount = 0

    let gate = OverlayFirstRenderGate(
      schedule: defaultScheduler.schedule,
      construct: {
        constructionCount += 1
        return NSView()
      },
      didBecomeReady: { _ in })

    gate.scheduleIfNeeded()  // demand-driven, wins the race
    gate.scheduleIfNeeded(using: overrideScheduler.schedule)  // prewarm, arrives second

    #expect(defaultScheduler.queued.count == 1)
    #expect(overrideScheduler.queued.isEmpty, "the loser's scheduler is never invoked")

    defaultScheduler.fireAll()
    #expect(constructionCount == 1, "construction happens exactly once, via the winner")
  }

  @Test("prewarm scheduling first makes a later demand-driven call a no-op")
  func prewarmFirstMakesDemandDrivenANoOp() {
    // Race direction 2 (plan §5/§7): the mirror image — the override
    // scheduler wins, the default scheduler never receives anything.
    let defaultScheduler = ManualScheduler()
    let overrideScheduler = ManualScheduler()
    var constructionCount = 0
    var readyCallCount = 0

    let gate = OverlayFirstRenderGate(
      schedule: defaultScheduler.schedule,
      construct: {
        constructionCount += 1
        return NSView()
      },
      didBecomeReady: { _ in readyCallCount += 1 })

    gate.scheduleIfNeeded(using: overrideScheduler.schedule)  // prewarm, wins the race
    gate.scheduleIfNeeded()  // demand-driven, arrives second (an early keypress)

    #expect(overrideScheduler.queued.count == 1)
    #expect(defaultScheduler.queued.isEmpty, "the loser's scheduler is never invoked")

    overrideScheduler.fireAll()
    #expect(constructionCount == 1, "construction happens exactly once, via the winner")
    #expect(readyCallCount == 1, "readiness fires exactly once regardless of which side won")
  }
}
