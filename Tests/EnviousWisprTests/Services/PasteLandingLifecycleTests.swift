import ApplicationServices
import EnviousWisprServices
import Foundation
import Testing

/// The paste landing check's preparation primitives (#3106 step 1, chunk 2): window identity, the
/// focus query, notification registration, and the ONE cumulative preparation budget.
///
/// When one of these fails, the check either delays a paste past its bound (a helper that hands
/// each call a fresh full timeout), calls a stale or wrong window "same" or "different", or reports
/// a partial registration as complete, so step 2 would trust a verdict it cannot back.
///
/// Every answer comes from `PastedRegionFakeAX`; the clock is `PastedRegionFakeScheduler`. Nothing
/// here talks to a real application.
@MainActor
@Suite("Paste landing check: preparation primitives (#3106)", .tags(.productOutcome))
struct PasteLandingLifecycleTests {

  private static let pid: pid_t = 42
  private static let app = PastedRegionFakeAX.app(pid)
  private static let field = PastedRegionFakeAX.field(pid)
  private static let fieldPid = pid + 10_000
  /// Two distinct window handles, compared with `CFEqual` only.
  private static let windowA = AXUIElementCreateApplication(7_001)
  private static let windowB = AXUIElementCreateApplication(7_002)

  private func budget(
    _ ax: PastedRegionFakeAX, tickMs: Int = 0, totalMs: Int = 500
  ) -> (PasteLandingPrepareBudget, PastedRegionFakeScheduler) {
    let clock = PastedRegionFakeScheduler()
    clock.tickPerNowRead = tickMs
    return (PasteLandingPrepareBudget(totalMs: totalMs, scheduler: clock, ax: ax), clock)
  }

  // MARK: Window identity

  @Test("Both windows read as elements: same when CFEqual, different otherwise")
  func sameAndDifferentWindow() {
    let ax = PastedRegionFakeAX()
    ax.windows[Self.fieldPid] = .window(Self.windowA)
    ax.focusedWindows[Self.pid] = .window(Self.windowA)
    #expect(
      PasteLandingCheck.targetWindow(
        captured: Self.field, application: Self.app, ax: ax, budget: budget(ax).0) == .same)
    ax.focusedWindows[Self.pid] = .window(Self.windowB)
    #expect(
      PasteLandingCheck.targetWindow(
        captured: Self.field, application: Self.app, ax: ax, budget: budget(ax).0) == .different)
  }

  @Test("No captured field: unknown, and no Accessibility call is made")
  func noCapturedTarget() {
    let ax = PastedRegionFakeAX()
    ax.focusedWindows[Self.pid] = .window(Self.windowA)
    #expect(
      PasteLandingCheck.targetWindow(
        captured: nil, application: Self.app, ax: ax, budget: budget(ax).0) == .unknown)
    #expect(ax.landingCalls.isEmpty)
  }

  @Test("Unsupported, wrong type, stale element and cannot-complete are all unknown, on either side")
  func unreadableWindows() {
    // A loop, not `arguments:`: the window read carries an `AXUIElement`, which is not Sendable.
    let bads: [PastedRegionWindowRead] = [
      .absent, .notElement, .failed(.invalidUIElement), .failed(.cannotComplete),
    ]
    for bad in bads { assertUnreadable(bad) }
  }

  private func assertUnreadable(_ bad: PastedRegionWindowRead) {
    let ax = PastedRegionFakeAX()
    ax.windows[Self.fieldPid] = bad
    ax.focusedWindows[Self.pid] = .window(Self.windowA)
    #expect(
      PasteLandingCheck.targetWindow(
        captured: Self.field, application: Self.app, ax: ax, budget: budget(ax).0) == .unknown)
    #expect(ax.landingCalls.map(\.call) == ["window"], "the second read is not made")

    let other = PastedRegionFakeAX()
    other.windows[Self.fieldPid] = .window(Self.windowA)
    other.focusedWindows[Self.pid] = bad
    #expect(
      PasteLandingCheck.targetWindow(
        captured: Self.field, application: Self.app, ax: other, budget: budget(other).0)
        == .unknown)
  }

  @Test("The fake's unscripted window answer is a failure, never a window")
  func fakeDefaultIsFailure() {
    let ax = PastedRegionFakeAX()
    #expect(
      PasteLandingCheck.targetWindow(
        captured: Self.field, application: Self.app, ax: ax, budget: budget(ax).0) == .unknown)
  }

  // MARK: Focus

  private func focus(_ ax: PastedRegionFakeAX, _ prepare: PasteLandingPrepareBudget)
    -> PasteLandingFocus?
  {
    PasteLandingCheck.focus(of: Self.app, pid: Self.pid, ax: ax, budget: prepare)
  }

  @Test("A genuine no-focus answer and a failed query stay two different facts")
  func noFocusVersusFailedQuery() {
    let ax = PastedRegionFakeAX()
    ax.focusedByApplication[Self.pid] = .noFocus
    guard case .noFocus = focus(ax, budget(ax).0) else {
      Issue.record("expected noFocus")
      return
    }
    ax.focusedByApplication[Self.pid] = .queryFailed(.cannotComplete)
    guard case .unreadable = focus(ax, budget(ax).0) else {
      Issue.record("expected unreadable")
      return
    }
  }

  @Test("The focused element must belong to the target: foreign or unreadable owner is unreadable")
  func focusedElementOwner() {
    let ax = PastedRegionFakeAX()
    ax.focusedByApplication[Self.pid] = .element(Self.field)
    guard case .element = focus(ax, budget(ax).0) else {
      Issue.record("a field the target owns is the element")
      return
    }
    ax.elementOwners[Self.fieldPid] = 99  // owned by another process
    guard case .unreadable = focus(ax, budget(ax).0) else {
      Issue.record("a foreign element must never read as the target's field, nor as no focus")
      return
    }
    ax.elementOwners[Self.fieldPid] = .some(nil)  // the owner cannot be read
    guard case .unreadable = focus(ax, budget(ax).0) else {
      Issue.record("an unreadable owner is unreadable")
      return
    }
  }

  @Test("The owner read is budgeted on the element's own handle, and a refusal stops it")
  func ownerReadIsBudgeted() {
    let ax = PastedRegionFakeAX()
    ax.focusedByApplication[Self.pid] = .element(Self.field)
    // 250 ms per clock read: the focus query is admitted (250 of 500 spent), the owner read is not.
    let (prepare, _) = budget(ax, tickMs: 250)
    #expect(focus(ax, prepare) == nil)
    #expect(prepare.refusal == .exhausted)
    #expect(ax.landingCalls.map(\.call) == ["focusedElement"], "no owner read after the refusal")
  }

  // MARK: The budget

  @Test("Each call gets the REMAINING time, on the exact handle it messages")
  func remainingTimeOnExactHandle() {
    let ax = PastedRegionFakeAX()
    ax.windows[Self.fieldPid] = .window(Self.windowA)
    ax.focusedWindows[Self.pid] = .window(Self.windowA)
    // The clock moves 100 ms on every read, so the second call must see less time than the first.
    let (prepare, _) = budget(ax, tickMs: 100)
    _ = PasteLandingCheck.targetWindow(
      captured: Self.field, application: Self.app, ax: ax, budget: prepare)
    #expect(ax.timeoutsSet.map(\.0) == [Self.fieldPid, Self.pid], "field first, then application")
    let seconds = ax.timeoutsSet.map(\.1)
    #expect(seconds.count == 2)
    #expect(seconds == [0.4, 0.3], "500 total: 100 spent, then 200 spent")
    #expect(prepare.refusal == nil)
  }

  @Test("A spent budget refuses, remembers it, and makes no further call")
  func exhaustionIsSticky() {
    let ax = PastedRegionFakeAX()
    ax.focusedByApplication[Self.pid] = .noFocus
    let (prepare, clock) = budget(ax)
    clock.jump(ms: 500)
    #expect(PasteLandingCheck.focus(of: Self.app, pid: Self.pid, ax: ax, budget: prepare) == nil)
    #expect(prepare.refusal == .exhausted)
    #expect(ax.landingCalls.isEmpty)
    #expect(ax.timeoutsSet.isEmpty, "no timeout is installed for a call that will not run")
    #expect(prepare.elapsedMs == 500)
    ax.focusedByApplication[Self.pid] = .noFocus
    #expect(PasteLandingCheck.focus(of: Self.app, pid: Self.pid, ax: ax, budget: prepare) == nil, "still refused")
    #expect(ax.landingCalls.isEmpty)
  }

  @Test("A timeout that cannot be installed refuses the call instead of running it unbounded")
  func timeoutInstallFailureRefuses() {
    let ax = PastedRegionFakeAX()
    ax.timeoutFailsFor = [Self.pid]
    ax.focusedByApplication[Self.pid] = .noFocus
    let (prepare, _) = budget(ax)
    #expect(PasteLandingCheck.focus(of: Self.app, pid: Self.pid, ax: ax, budget: prepare) == nil)
    #expect(prepare.refusal == .timeoutNotInstalled)
    #expect(ax.landingCalls.isEmpty)
    // Sticky: with installs working again, a call on ANOTHER handle is still refused.
    ax.timeoutFailsFor = []
    let installsBefore = ax.timeoutsSet.count
    #expect(
      PasteLandingCheck.targetWindow(
        captured: Self.field, application: Self.app, ax: ax, budget: prepare) == .unknown)
    #expect(prepare.refusal == .timeoutNotInstalled)
    #expect(ax.timeoutsSet.count == installsBefore, "no new timeout installed")
    #expect(ax.landingCalls.isEmpty, "no AX read after a refusal")
  }

  @Test("Exhaustion in the middle of a range read stops it before the next call")
  func exhaustionMidReadText() {
    let ax = PastedRegionFakeAX()
    ax.counts = [.count(5)]
    ax.rangeReads = [.text("Hello")]
    // Budget creation reads the clock once, then every admit reads it once: 200 ms apart, so the
    // third admit (the second count) finds 600 of 500 ms spent.
    let (prepare, _) = budget(ax, tickMs: 200)
    let read = PastedRegionObserver.readText(
      of: Self.field, using: .range, ax: ax, admit: prepare.admit)
    #expect(read == nil, "a refusal is not an answer about the field")
    #expect(prepare.refusal == .exhausted)
    #expect(ax.countCalls == 1)
    #expect(ax.rangeCalls.count == 1)
  }

  @Test("The whole-text read falls back to the range reader through the same budget")
  func wholeTextFallsBackUnderOneBudget() {
    let ax = PastedRegionFakeAX()
    ax.reads = [.absent]
    ax.counts = [.count(5)]
    ax.rangeReads = [.text("Hello")]
    let (prepare, _) = budget(ax, tickMs: 10)
    let read = PastedRegionObserver.readWholeText(of: Self.field, ax: ax, admit: prepare.admit)
    #expect(read == .text("Hello"))
    #expect(
      ax.timeoutsSet.map(\.1) == [0.49, 0.48, 0.47, 0.46], "four calls, each on what is left")
  }

  @Test("The whole-text read keeps the 20,000-unit ceiling and does not retry a failed value")
  func wholeTextCeilingAndFailedValue() {
    let ax = PastedRegionFakeAX()
    ax.reads = [.text(String(repeating: "a", count: 20_001))]
    #expect(
      PastedRegionObserver.readWholeText(of: Self.field, ax: ax, admit: { _ in true }) == .tooLong)
    let failing = PastedRegionFakeAX()
    failing.reads = [.failed(.cannotComplete)]
    #expect(
      PastedRegionObserver.readWholeText(of: Self.field, ax: failing, admit: { _ in true })
        == .failed(.cannotComplete))
    #expect(failing.countCalls == 0, "a failed value read is the host not answering")
  }

  // MARK: Registration

  private func register(
    _ ax: PastedRegionFakeAX, element: AXUIElement?, budget prepare: PasteLandingPrepareBudget
  ) -> (any PastedRegionAXRegistration)? {
    ax.registerLanding(
      pid: Self.pid, element: element, application: Self.app, admit: prepare.admit,
      handler: { _ in })
  }

  @Test("A full registration reports all three notifications")
  func fullRegistration() {
    let ax = PastedRegionFakeAX()
    let registration = register(ax, element: Self.field, budget: budget(ax).0)
    #expect(
      registration?.registeredNotifications
        == PasteLandingCheck.requiredNotifications(hasElement: true))
  }

  @Test("A partial registration is returned and is recognisably incomplete")
  func partialRegistration() {
    let ax = PastedRegionFakeAX()
    ax.landingNotificationFailures = [.elementDestroyed]
    let registration = register(ax, element: Self.field, budget: budget(ax).0)
    #expect(registration?.registeredNotifications == [.valueChanged, .focusedElementChanged])
    #expect(
      registration?.registeredNotifications
        != PasteLandingCheck.requiredNotifications(hasElement: true))
  }

  @Test("Nothing registered: nil, never an empty registration that looks usable")
  func zeroRegistration() {
    let ax = PastedRegionFakeAX()
    ax.landingNotificationFailures = Set(PastedRegionAXNotification.allCases)
    #expect(register(ax, element: Self.field, budget: budget(ax).0) == nil)
  }

  @Test("With nothing focused only the application's focus notification is required and asked")
  func noElementRegistration() {
    let ax = PastedRegionFakeAX()
    let registration = register(ax, element: nil, budget: budget(ax).0)
    #expect(registration?.registeredNotifications == [.focusedElementChanged])
    #expect(PasteLandingCheck.requiredNotifications(hasElement: false) == [.focusedElementChanged])
    #expect(ax.landingCalls.map(\.call) == ["add:focusedElementChanged"])
  }

  @Test("A spent budget creates no observer at all")
  func spentBudgetCreatesNoObserver() {
    let ax = PastedRegionFakeAX()
    let (prepare, clock) = budget(ax)
    clock.jump(ms: 500)
    #expect(register(ax, element: Self.field, budget: prepare) == nil)
    #expect(ax.landingObserversCreated == 0)
    #expect(ax.landingCalls.isEmpty)
  }

  @Test("Exhaustion mid-registration stops before the next add and keeps what succeeded")
  func exhaustionMidRegistration() {
    let ax = PastedRegionFakeAX()
    // 200 ms per clock read: the observer (application) and the first add are admitted, the
    // second add finds 600 of 500 ms spent.
    let (prepare, _) = budget(ax, tickMs: 200)
    let registration = register(ax, element: Self.field, budget: prepare)
    #expect(registration?.registeredNotifications == [.valueChanged])
    #expect(prepare.refusal == .exhausted)
    #expect(
      !ax.landingCalls.map(\.call).contains("add:focusedElementChanged"),
      "no call after the refusal")
  }

  @Test("The learn watcher's registration answers as before: no claimed notifications")
  func legacyRegistrationUnchanged() {
    let ax = PastedRegionFakeAX()
    let registration = ax.register(
      pid: Self.pid, element: Self.field, application: Self.app, handler: { _ in })
    #expect(registration?.registeredNotifications.isEmpty == true)
    #expect(ax.landingCalls.isEmpty)
  }
}
