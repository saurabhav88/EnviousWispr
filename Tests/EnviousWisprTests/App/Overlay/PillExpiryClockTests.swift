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
    var dispatches: [(id: PresentationID, target: OverlayExpiryTarget)] = []
    let now = Date(timeIntervalSince1970: 1_000)

    private(set) lazy var clock = PillExpiryClock(
      schedule: .manual { [unowned self] in self.scheduled.append($0) },
      now: { [unowned self] in self.now },
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
    #expect(window == OverlayDwellWindow(id: pill, startedAt: rig.now, seconds: 3))
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
}
