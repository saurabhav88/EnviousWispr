import Foundation
import Testing

@testable import EnviousWisprAppKit

/// `PillExpiryClock` is the sole dismissal clock (#2377 Phase 5, C2).
///
/// **Every receipt here is deterministic: no sleeps, no elapsed time, no polling.**
/// `OverlayScheduler.manual` hands the test the scheduled work itself, so a dwell
/// fires because the test fires it. `now` is injected, so a published window
/// carries a timestamp the test chose rather than one it has to tolerate.
@Suite(.tags(.productOutcome))
@MainActor
struct PillExpiryClockTests {

  /// One clock plus everything it reported, so a row asserts on what was
  /// published and dispatched rather than on the clock's private state.
  @MainActor
  private final class Rig {
    var scheduled: [OverlayScheduledWork] = []
    var published: [OverlayDwellWindow?] = []
    var scheduledSeconds: [Double] = []
    var dispatches: [(id: PresentationID, target: OverlayExpiryTarget)] = []
    var now = Date(timeIntervalSince1970: 1_000)
    /// The steady clock the timer runs on; only real elapsed time moves it.
    var uptime: TimeInterval = 5_000

    /// Real time passing: both clocks move.
    func advance(by seconds: Double) {
      now = now.addingTimeInterval(seconds)
      uptime += seconds
    }

    /// A wall-clock correction: only the `Date` moves, the steady clock does not.
    func jumpWallClock(by seconds: Double) { now = now.addingTimeInterval(seconds) }

    private(set) lazy var clock = PillExpiryClock(
      schedule: OverlayScheduler { [unowned self] seconds, body in
        let work = OverlayScheduledWork(body: body)
        self.scheduled.append(work)
        self.scheduledSeconds.append(seconds)
        return work
      },
      now: { [unowned self] in self.now },
      uptime: { [unowned self] in self.uptime },
      publishDwell: { [unowned self] in self.published.append($0) })

    func recordFired(_ id: PresentationID, _ target: OverlayExpiryTarget) {
      dispatches.append((id, target))
    }
  }

  private static func id() -> PresentationID { PresentationID(rawValue: UUID()) }

  // MARK: - Preparing versus starting

  @Test("preparing an arm schedules nothing and publishes no dwell")
  func prepareDoesNotArm() {
    let rig = Rig()
    let pill = Self.id()

    _ = rig.clock.prepare(
      .arm(id: pill, seconds: 3, target: .presentation),
      onExpiry: { rig.recordFired($0, $1) })

    #expect(rig.scheduled.isEmpty, "preparing armed a timer before the pill was on screen")
    #expect(rig.published.isEmpty, "preparing published a dwell before the pill was on screen")
  }

  @Test("starting publishes the injected instant and arms exactly once")
  func startArmsOnceWithTheInjectedInstant() throws {
    let rig = Rig()
    let pill = Self.id()

    let start = rig.clock.prepare(
      .arm(id: pill, seconds: 3, target: .presentation),
      onExpiry: { rig.recordFired($0, $1) })
    start()

    #expect(rig.scheduled.count == 1, "starting armed \(rig.scheduled.count) timers")
    let window = try #require(rig.published.last ?? nil, "starting published no dwell window")
    #expect(
      window
        == OverlayDwellWindow(
          id: pill, startedAt: rig.now, seconds: 3, startedUptime: rig.uptime),
      "a running window carries the injected steady-clock reading it started at")
  }

  // MARK: - Cancellation is immediate

  @Test("cancel clears the armed work and the dwell without waiting to be started")
  func cancelIsImmediate() throws {
    let rig = Rig()
    let pill = Self.id()
    rig.clock.prepare(
      .arm(id: pill, seconds: 3, target: .presentation), onExpiry: { rig.recordFired($0, $1) })()
    let armed = try #require(rig.scheduled.first)

    _ = rig.clock.prepare(.cancel, onExpiry: { rig.recordFired($0, $1) })

    #expect(armed.isCancelled, "the outgoing work survived a cancel")
    #expect(rig.published.last ?? nil == nil, "a cancel left the dwell published")
  }

  @Test("a replacement cancels the outgoing work, and firing it dispatches nothing")
  func replacementCancelsTheOutgoingWork() throws {
    let rig = Rig()
    let first = Self.id()
    let second = Self.id()
    rig.clock.prepare(
      .arm(id: first, seconds: 3, target: .presentation), onExpiry: { rig.recordFired($0, $1) })()
    let outgoing = try #require(rig.scheduled.first)

    // Preparing the replacement is enough: cancellation does not wait for the
    // incoming pill to land, or a dead timer stays live across the gap.
    _ = rig.clock.prepare(
      .arm(id: second, seconds: 3, target: .presentation), onExpiry: { rig.recordFired($0, $1) })
    #expect(outgoing.isCancelled, "the outgoing timer survived its replacement")

    outgoing.fire()
    #expect(rig.dispatches.isEmpty, "a cancelled timer still dispatched an expiry")
  }

  /// `OverlayScheduledWork.fire()` on a cancelled handle only proves the
  /// scheduler's own cancel guard. This captures the scheduled CLOSURE through the
  /// scheduler injection and invokes it directly, so the clock's own identity
  /// check is what is under test. The same presentation id is armed twice: the id
  /// cannot distinguish the arms, only the per-arm identity can.
  @Test("an invalidated callback for the same presentation id dispatches nothing")
  func invalidatedCallbackForSamePresentationDispatchesNothing() throws {
    var bodies: [() -> Void] = []
    var dispatches: [(id: PresentationID, target: OverlayExpiryTarget)] = []
    let clock = PillExpiryClock(
      schedule: OverlayScheduler { _, body in
        bodies.append(body)
        return OverlayScheduledWork(body: body)
      },
      now: { Date(timeIntervalSince1970: 1_000) },
      uptime: { 5_000 },
      publishDwell: { _ in })
    let pill = Self.id()

    clock.prepare(
      .arm(id: pill, seconds: 3, target: .presentation), onExpiry: { dispatches.append(($0, $1)) })()
    clock.prepare(
      .arm(id: pill, seconds: 3, target: .presentation), onExpiry: { dispatches.append(($0, $1)) })()
    #expect(bodies.count == 2, "each started arm schedules its own callback")

    bodies[0]()
    #expect(dispatches.isEmpty, "a replaced arm's callback dispatched for the same presentation")

    // Positive control: the current callback dispatches, once.
    bodies[1]()
    bodies[1]()
    #expect(dispatches.count == 1, "the current callback dispatched \(dispatches.count) times")
    #expect(dispatches.first?.id == pill)

    // Cancel invalidates a started arm immediately, before its timer is touched.
    clock.prepare(
      .arm(id: pill, seconds: 3, target: .inPanelNotice), onExpiry: { dispatches.append(($0, $1)) })()
    _ = clock.prepare(.cancel, onExpiry: { dispatches.append(($0, $1)) })
    bodies[2]()
    #expect(dispatches.count == 1, "a cancelled arm's callback still dispatched")
  }

  /// A start closure that has been superseded must not arm, and starting the live
  /// one twice must not arm twice.
  ///
  /// The sequence is reachable: the director prepares before it renders and starts
  /// only from a successful presentation, so a DEFERRED first render leaves a
  /// start closure outstanding while a second plan runs to completion. Without the
  /// token both timers are live while the clock names only one of them.
  @Test("a superseded prepared arm cannot start or create a second timer")
  func supersededPreparedArmCannotStart() throws {
    let rig = Rig()
    let first = Self.id()
    let second = Self.id()

    let staleStart = rig.clock.prepare(
      .arm(id: first, seconds: 3, target: .presentation),
      onExpiry: { rig.recordFired($0, $1) })
    let liveStart = rig.clock.prepare(
      .arm(id: second, seconds: 3, target: .inPanelNotice),
      onExpiry: { rig.recordFired($0, $1) })

    staleStart()
    liveStart()
    liveStart()

    #expect(rig.scheduled.count == 1, "the clock armed \(rig.scheduled.count) timers")
    try #require(rig.scheduled.first).fire()
    #expect(rig.dispatches.count == 1, "firing dispatched \(rig.dispatches.count) expiries")
    #expect(rig.dispatches.first?.id == second, "a superseded arm's pill was dismissed")
    #expect(rig.dispatches.first?.target == .inPanelNotice)
  }

  // MARK: - What the live work dispatches

  @Test(
    "the live work dispatches exactly its captured id and target",
    arguments: [OverlayExpiryTarget.presentation, .inPanelNotice])
  func firingDispatchesTheCapturedIdAndTarget(target: OverlayExpiryTarget) throws {
    let rig = Rig()
    let pill = Self.id()
    rig.clock.prepare(.arm(id: pill, seconds: 4, target: target), onExpiry: { rig.recordFired($0, $1) })()

    try #require(rig.scheduled.first).fire()

    #expect(rig.dispatches.count == 1, "firing dispatched \(rig.dispatches.count) expiries")
    let dispatched = try #require(rig.dispatches.first)
    #expect(dispatched.id == pill, "the timer dispatched an id it was not armed for")
    #expect(dispatched.target == target, "the timer dispatched the wrong target")
  }

  // MARK: - `.unchanged` leaves the clock alone

  @Test("unchanged preserves the running work and the published dwell")
  func unchangedLeavesTheClockAlone() throws {
    let rig = Rig()
    let pill = Self.id()
    rig.clock.prepare(
      .arm(id: pill, seconds: 3, target: .presentation), onExpiry: { rig.recordFired($0, $1) })()
    let armed = try #require(rig.scheduled.first)
    let publishedCount = rig.published.count

    let noop = rig.clock.prepare(.unchanged, onExpiry: { rig.recordFired($0, $1) })
    noop()

    #expect(!armed.isCancelled, "an unchanged plan cancelled the running clock")
    #expect(rig.scheduled.count == 1, "an unchanged plan armed a second timer")
    #expect(
      rig.published.count == publishedCount,
      "an unchanged plan republished the dwell, which restarts a countdown that is still running")
  }

  // MARK: - Hover pause and resume (#4675)

  /// The latest published window, which a row reads rather than clock state.
  private static func latest(_ rig: Rig) throws -> OverlayDwellWindow {
    try #require(rig.published.last ?? nil, "no dwell window is published")
  }

  @Test("pause freezes the remainder of the original total and invalidates the armed callback")
  func pauseStoresTheRemainder() throws {
    let rig = Rig()
    let pill = Self.id()
    rig.clock.prepare(
      .arm(id: pill, seconds: 12, target: .presentation), onExpiry: { rig.recordFired($0, $1) })()
    let armed = try #require(rig.scheduled.first)
    rig.advance(by: 4)

    _ = rig.clock.prepare(.pause, onExpiry: { rig.recordFired($0, $1) })

    #expect(armed.isCancelled, "pause left the armed callback live")
    let frozen = try Self.latest(rig)
    #expect(frozen.pausedRemaining == 8)
    #expect(frozen.totalSeconds == 12)
    #expect(frozen.isPaused)
    // Frozen: the same share at any later instant.
    #expect(frozen.elapsedFraction(at: rig.now) == 4.0 / 12.0)
    #expect(frozen.elapsedFraction(at: rig.now.addingTimeInterval(60)) == 4.0 / 12.0)
    #expect(frozen.remaining(at: rig.now.addingTimeInterval(60)) == 8)
    armed.fire()
    #expect(rig.dispatches.isEmpty, "a paused dwell still expired")
  }

  @Test("a wall-clock jump, forward or backward, cannot change the frozen remainder")
  func pauseIgnoresWallClockJumps() throws {
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { _, _ in }
    // Forward jump of 60 s and backward jump of 54 s, each after 3 of 12 s of real time.
    // Reading the wall clock would freeze 0 s (forward: deadline - now < 0) or 66 s
    // (backward: clamped to 12); the steady clock freezes 9 s both times.
    for jump in [60.0, -54.0] {
      let rig = Rig()
      let pill = Self.id()
      rig.clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: onExpiry)()
      rig.advance(by: 3)
      rig.jumpWallClock(by: jump)

      _ = rig.clock.prepare(.pause, onExpiry: onExpiry)

      let frozen = try Self.latest(rig)
      #expect(frozen.isPaused)
      #expect(frozen.pausedRemaining == 9, "a \(jump) s wall-clock jump changed the frozen remainder")
      #expect(frozen.totalSeconds == 12)

      rig.clock.prepare(.resume(id: pill, floorSeconds: 2), onExpiry: onExpiry)()
      #expect(rig.scheduledSeconds.last == 9, "resume did not arm the steady-clock remainder")
    }
  }

  @Test("an invalidated callback does not fire after a pause, even when called directly")
  func pausedCallbackDispatchesNothing() throws {
    var bodies: [() -> Void] = []
    var dispatches: [PresentationID] = []
    let clock = PillExpiryClock(
      schedule: OverlayScheduler { _, body in
        bodies.append(body)
        return OverlayScheduledWork(body: body)
      },
      now: { Date(timeIntervalSince1970: 1_000) },
      uptime: { 5_000 },
      publishDwell: { _ in })
    let pill = Self.id()
    clock.prepare(
      .arm(id: pill, seconds: 12, target: .presentation), onExpiry: { id, _ in dispatches.append(id) })()

    _ = clock.prepare(.pause, onExpiry: { id, _ in dispatches.append(id) })
    bodies[0]()

    #expect(dispatches.isEmpty, "the callback armed before the pause still dispatched")
  }

  @Test("resume arms the ordinary remainder and draws it as a share of the original total")
  func resumeArmsTheRemainder() throws {
    let rig = Rig()
    let pill = Self.id()
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { rig.recordFired($0, $1) }
    rig.clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: onExpiry)()
    rig.advance(by: 4)
    _ = rig.clock.prepare(.pause, onExpiry: onExpiry)
    rig.advance(by: 30)

    let start = rig.clock.prepare(.resume(id: pill, floorSeconds: 2), onExpiry: onExpiry)
    #expect(rig.scheduled.count == 1, "resume armed before the host accepted the pill")
    start()

    #expect(rig.scheduled.count == 2)
    #expect(rig.scheduledSeconds.last == 8, "the pause time was counted against the dwell")
    let running = try Self.latest(rig)
    #expect(!running.isPaused)
    #expect(running.seconds == 8)
    #expect(running.totalSeconds == 12)
    #expect(running.startedAt == rig.now)
    #expect(running.elapsedFraction(at: rig.now) == 4.0 / 12.0)

    try #require(rig.scheduled.last).fire()
    #expect(rig.dispatches.count == 1)
    #expect(rig.dispatches.first?.id == pill)
    #expect(rig.dispatches.first?.target == .presentation)
  }

  @Test("resume with half a second left arms the two second floor and the rail moves back")
  func resumeFloorRaisesTheRemainder() throws {
    let rig = Rig()
    let pill = Self.id()
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { rig.recordFired($0, $1) }
    rig.clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: onExpiry)()
    rig.advance(by: 11.5)
    _ = rig.clock.prepare(.pause, onExpiry: onExpiry)
    let frozen = try Self.latest(rig)
    #expect(frozen.pausedRemaining == 0.5)

    rig.clock.prepare(.resume(id: pill, floorSeconds: 2), onExpiry: onExpiry)()

    #expect(rig.scheduledSeconds.last == 2)
    let running = try Self.latest(rig)
    #expect(running.totalSeconds == 12, "the floor must not change the original total")
    #expect(running.elapsedFraction(at: rig.now) == 10.0 / 12.0)
    #expect(
      running.elapsedFraction(at: rig.now) < frozen.elapsedFraction(at: rig.now),
      "the added time did not move the line back")
  }

  @Test("cancel discards a paused dwell, so a later resume starts nothing")
  func cancelDiscardsPausedState() {
    let rig = Rig()
    let pill = Self.id()
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { rig.recordFired($0, $1) }
    rig.clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: onExpiry)()
    _ = rig.clock.prepare(.pause, onExpiry: onExpiry)
    _ = rig.clock.prepare(.cancel, onExpiry: onExpiry)

    rig.clock.prepare(.resume(id: pill, floorSeconds: 2), onExpiry: onExpiry)()

    #expect(rig.scheduled.count == 1, "a cancelled pill's dwell came back")
    #expect(rig.published.last ?? nil == nil)
  }

  @Test("a replacement discards the outgoing paused dwell")
  func replacementDiscardsPausedState() {
    let rig = Rig()
    let first = Self.id()
    let second = Self.id()
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { rig.recordFired($0, $1) }
    rig.clock.prepare(.arm(id: first, seconds: 12, target: .presentation), onExpiry: onExpiry)()
    _ = rig.clock.prepare(.pause, onExpiry: onExpiry)
    rig.clock.prepare(.arm(id: second, seconds: 12, target: .presentation), onExpiry: onExpiry)()
    #expect(rig.scheduled.count == 2)

    rig.clock.prepare(.resume(id: first, floorSeconds: 2), onExpiry: onExpiry)()

    #expect(rig.scheduled.count == 2, "the replaced pill's remainder was resumed")
    #expect(rig.scheduledSeconds.last == 12)
  }

  @Test("resume for another presentation id starts nothing")
  func resumeForAnotherIDStartsNothing() {
    let rig = Rig()
    let pill = Self.id()
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { rig.recordFired($0, $1) }
    rig.clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: onExpiry)()
    _ = rig.clock.prepare(.pause, onExpiry: onExpiry)

    rig.clock.prepare(.resume(id: Self.id(), floorSeconds: 2), onExpiry: onExpiry)()

    #expect(rig.scheduled.count == 1)
  }

  @Test("a pause before the first start holds the whole dwell, and the stale start cannot arm")
  func pauseBeforeStartHoldsTheWholeDwell() throws {
    let rig = Rig()
    let pill = Self.id()
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { rig.recordFired($0, $1) }
    let start = rig.clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: onExpiry)

    _ = rig.clock.prepare(.pause, onExpiry: onExpiry)
    start()
    #expect(rig.scheduled.isEmpty, "a start prepared before the pause armed under the hover")

    rig.clock.prepare(.resume(id: pill, floorSeconds: 2), onExpiry: onExpiry)()
    #expect(rig.scheduledSeconds == [12])
    #expect(try Self.latest(rig).totalSeconds == 12)
  }

  @Test("a start prepared by resume is dropped when a pause lands before it runs")
  func pauseBeforeResumeStartsDropsTheStart() {
    let rig = Rig()
    let pill = Self.id()
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { rig.recordFired($0, $1) }
    rig.clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: onExpiry)()
    _ = rig.clock.prepare(.pause, onExpiry: onExpiry)
    let resumeStart = rig.clock.prepare(.resume(id: pill, floorSeconds: 2), onExpiry: onExpiry)

    _ = rig.clock.prepare(.pause, onExpiry: onExpiry)
    resumeStart()

    #expect(rig.scheduled.count == 1, "a superseded resume start armed a timer")
  }

  // MARK: - Entering Pending (#4675)

  @Test("enterPending from a running dwell with 1 s left arms the 3 s minimum and invalidates the old callback")
  func enterPendingFromRunningRaisesToTheMinimum() throws {
    var bodies: [() -> Void] = []
    var dispatches: [PresentationID] = []
    var now = Date(timeIntervalSince1970: 1_000)
    var published: [OverlayDwellWindow?] = []
    var seconds: [Double] = []
    let clock = PillExpiryClock(
      schedule: OverlayScheduler { after, body in
        bodies.append(body)
        seconds.append(after)
        return OverlayScheduledWork(body: body)
      },
      now: { now }, uptime: { now.timeIntervalSince1970 }, publishDwell: { published.append($0) })
    let pill = Self.id()
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { id, _ in dispatches.append(id) }
    clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: onExpiry)()
    now = now.addingTimeInterval(11)

    clock.prepare(.enterPending(id: pill, minimumSeconds: 3), onExpiry: onExpiry)()

    #expect(seconds == [12, 3], "1 s was left, so the minimum is what arms")
    let window = try #require(published.last ?? nil)
    #expect(
      window
        == OverlayDwellWindow(
          id: pill, startedAt: now, seconds: 3, totalSeconds: 12,
          startedUptime: now.timeIntervalSince1970))
    bodies[0]()
    #expect(dispatches.isEmpty, "the 12 s callback fired after Pending replaced it")
    bodies[1]()
    bodies[1]()
    #expect(dispatches == [pill], "the Pending callback dispatches exactly once")
  }

  @Test("enterPending keeps a remainder above the minimum")
  func enterPendingKeepsALongRemainder() {
    let rig = Rig()
    let pill = Self.id()
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { rig.recordFired($0, $1) }
    rig.clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: onExpiry)()
    rig.advance(by: 4)

    rig.clock.prepare(.enterPending(id: pill, minimumSeconds: 3), onExpiry: onExpiry)()

    #expect(rig.scheduledSeconds == [12, 8], "8 s were left, which is above the 3 s minimum")
    #expect(rig.scheduled[0].isCancelled)
  }

  @Test("enterPending from a paused dwell uses the stored remainder, not the time spent paused, and consumes it")
  func enterPendingFromPaused() throws {
    let rig = Rig()
    let pill = Self.id()
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { rig.recordFired($0, $1) }
    rig.clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: onExpiry)()
    rig.advance(by: 4)
    _ = rig.clock.prepare(.pause, onExpiry: onExpiry)
    rig.advance(by: 30)

    rig.clock.prepare(.enterPending(id: pill, minimumSeconds: 3), onExpiry: onExpiry)()
    #expect(rig.scheduledSeconds == [12, 8], "the 30 s paused were counted against the dwell")
    let running = try Self.latest(rig)
    #expect(!running.isPaused && running.seconds == 8 && running.totalSeconds == 12)

    rig.clock.prepare(.resume(id: pill, floorSeconds: 2), onExpiry: onExpiry)()
    #expect(rig.scheduled.count == 2, "the paused remainder came back after Pending consumed it")

    // Below the minimum, from paused.
    let low = Rig()
    low.clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: { low.recordFired($0, $1) })()
    low.advance(by: 11.5)
    _ = low.clock.prepare(.pause, onExpiry: { low.recordFired($0, $1) })
    low.clock.prepare(.enterPending(id: pill, minimumSeconds: 3), onExpiry: { low.recordFired($0, $1) })()
    #expect(low.scheduledSeconds == [12, 3], "0.5 s was frozen, so the minimum arms")
    try #require(low.scheduled.last).fire()
    #expect(low.dispatches.map(\.id) == [pill])
  }

  @Test("enterPending for another presentation, or with nothing running, changes nothing")
  func enterPendingNeedsTheMatchingRemainder() {
    let rig = Rig()
    let pill = Self.id()
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { rig.recordFired($0, $1) }
    rig.clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: onExpiry)()
    let armed = rig.scheduled[0]
    let publishedBefore = rig.published.count

    rig.clock.prepare(.enterPending(id: Self.id(), minimumSeconds: 3), onExpiry: onExpiry)()
    #expect(!armed.isCancelled && rig.scheduled.count == 1, "another pill's Undo re-timed this dwell")
    #expect(rig.published.count == publishedBefore)
    armed.fire()
    #expect(rig.dispatches.map(\.id) == [pill], "the untouched dwell still expires")

    let empty = Rig()
    empty.clock.prepare(.enterPending(id: pill, minimumSeconds: 3), onExpiry: { empty.recordFired($0, $1) })()
    #expect(empty.scheduled.isEmpty && empty.published.isEmpty, "Pending armed with nothing to enter from")
  }

  @Test("enterPending does not touch a prepared start that has not begun")
  func enterPendingLeavesAPreparedStartAlone() {
    let rig = Rig()
    let pill = Self.id()
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { rig.recordFired($0, $1) }
    let start = rig.clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: onExpiry)

    rig.clock.prepare(.enterPending(id: pill, minimumSeconds: 3), onExpiry: onExpiry)()
    #expect(rig.scheduled.isEmpty, "Pending armed a timer for a pill the host has not accepted")

    start()
    #expect(rig.scheduledSeconds == [12], "the prepared start was lost")
  }

  @Test("a start prepared by enterPending is dropped when a cancel lands before it runs")
  func cancelBeforePendingStartDropsTheStart() {
    let rig = Rig()
    let pill = Self.id()
    let onExpiry: (PresentationID, OverlayExpiryTarget) -> Void = { rig.recordFired($0, $1) }
    rig.clock.prepare(.arm(id: pill, seconds: 12, target: .presentation), onExpiry: onExpiry)()
    let pendingStart = rig.clock.prepare(.enterPending(id: pill, minimumSeconds: 3), onExpiry: onExpiry)

    _ = rig.clock.prepare(.cancel, onExpiry: onExpiry)
    pendingStart()

    #expect(rig.scheduled.count == 1, "a superseded Pending start armed a timer")
    #expect(rig.published.last ?? nil == nil)
  }
}
