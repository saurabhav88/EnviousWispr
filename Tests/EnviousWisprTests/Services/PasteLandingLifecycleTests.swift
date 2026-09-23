import ApplicationServices
import EnviousWisprServices
import Foundation
import Testing

/// The arrival session's preparation primitives (#3106): window identity, the focus query,
/// notification registration, and the ONE cumulative preparation budget; then the session's
/// preparation, decision inputs and one report.
///
/// When one of these fails, the session either delays a paste past its bound (a helper that hands
/// each call a fresh full timeout), calls a stale or wrong window "same" or "different", or reports
/// a partial registration as complete, so step 2 would trust a verdict it cannot back.
///
/// Every answer comes from `PastedRegionFakeAX`; the clock is `PastedRegionFakeScheduler`. Nothing
/// here talks to a real application.
@MainActor
@Suite("Paste arrival session: preparation primitives (#3106)", .tags(.productOutcome))
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
      PasteArrivalCapture.targetWindow(
        captured: Self.field, application: Self.app, ax: ax, budget: budget(ax).0) == .same)
    ax.focusedWindows[Self.pid] = .window(Self.windowB)
    #expect(
      PasteArrivalCapture.targetWindow(
        captured: Self.field, application: Self.app, ax: ax, budget: budget(ax).0) == .different)
  }

  @Test("No captured field: unknown, and no Accessibility call is made")
  func noCapturedTarget() {
    let ax = PastedRegionFakeAX()
    ax.focusedWindows[Self.pid] = .window(Self.windowA)
    #expect(
      PasteArrivalCapture.targetWindow(
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
      PasteArrivalCapture.targetWindow(
        captured: Self.field, application: Self.app, ax: ax, budget: budget(ax).0) == .unknown)
    #expect(ax.landingCalls.map(\.call) == ["window"], "the second read is not made")

    let other = PastedRegionFakeAX()
    other.windows[Self.fieldPid] = .window(Self.windowA)
    other.focusedWindows[Self.pid] = bad
    #expect(
      PasteArrivalCapture.targetWindow(
        captured: Self.field, application: Self.app, ax: other, budget: budget(other).0)
        == .unknown)
  }

  @Test("The fake's unscripted window answer is a failure, never a window")
  func fakeDefaultIsFailure() {
    let ax = PastedRegionFakeAX()
    #expect(
      PasteArrivalCapture.targetWindow(
        captured: Self.field, application: Self.app, ax: ax, budget: budget(ax).0) == .unknown)
  }

  // MARK: Focus

  private func focus(_ ax: PastedRegionFakeAX, _ prepare: PasteLandingPrepareBudget)
    -> PasteLandingFocus?
  {
    PasteArrivalCapture.focus(of: Self.app, pid: Self.pid, ax: ax, budget: prepare)
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
    _ = PasteArrivalCapture.targetWindow(
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
    #expect(PasteArrivalCapture.focus(of: Self.app, pid: Self.pid, ax: ax, budget: prepare) == nil)
    #expect(prepare.refusal == .exhausted)
    #expect(ax.landingCalls.isEmpty)
    #expect(ax.timeoutsSet.isEmpty, "no timeout is installed for a call that will not run")
    #expect(prepare.elapsedMs == 500)
    ax.focusedByApplication[Self.pid] = .noFocus
    #expect(PasteArrivalCapture.focus(of: Self.app, pid: Self.pid, ax: ax, budget: prepare) == nil, "still refused")
    #expect(ax.landingCalls.isEmpty)
  }

  @Test("A timeout that cannot be installed refuses the call instead of running it unbounded")
  func timeoutInstallFailureRefuses() {
    let ax = PastedRegionFakeAX()
    ax.timeoutFailsFor = [Self.pid]
    ax.focusedByApplication[Self.pid] = .noFocus
    let (prepare, _) = budget(ax)
    #expect(PasteArrivalCapture.focus(of: Self.app, pid: Self.pid, ax: ax, budget: prepare) == nil)
    #expect(prepare.refusal == .timeoutNotInstalled)
    #expect(ax.landingCalls.isEmpty)
    // Sticky: with installs working again, a call on ANOTHER handle is still refused.
    ax.timeoutFailsFor = []
    let installsBefore = ax.timeoutsSet.count
    #expect(
      PasteArrivalCapture.targetWindow(
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
        == PasteArrivalCapture.requiredNotifications(hasElement: true))
  }

  @Test("A partial registration is returned and is recognisably incomplete")
  func partialRegistration() {
    let ax = PastedRegionFakeAX()
    ax.landingNotificationFailures = [.elementDestroyed]
    let registration = register(ax, element: Self.field, budget: budget(ax).0)
    #expect(registration?.registeredNotifications == [.valueChanged, .focusedElementChanged])
    #expect(
      registration?.registeredNotifications
        != PasteArrivalCapture.requiredNotifications(hasElement: true))
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
    #expect(PasteArrivalCapture.requiredNotifications(hasElement: false) == [.focusedElementChanged])
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

// MARK: - Lifecycle: the arrival session's preparation and one report (#3106 PR A)

extension PasteLandingLifecycleTests {

  /// A readable TextEdit-shaped target: pid 42 frontmost, its field focused and owned by it.
  @MainActor
  private final class Rig {
    let ax = PastedRegionFakeAX()
    let clock = PastedRegionFakeScheduler()
    var lines: [String] = []
    var reports: [PasteArrivalObservation] = []
    init(before: String = "Hello", after: String = "Hello") {
      ax.focusedByApplication[42] = .element(PastedRegionFakeAX.field(42))
      ax.focused[42] = .element(PastedRegionFakeAX.field(42))
      ax.reads = [.text(before), .text(after)]
      ax.selectedRange = .range(location: 5, length: 0)
    }
    func prepare(
      tier: PasteTier = .cgEvent, captured: AXUIElement? = PastedRegionFakeAX.field(42),
      payload: String = "send the draft", takeID: String = "TAKE-A",
      bundleID: String = "com.apple.TextEdit", restore: Double = 0
    ) -> PasteArrivalCapture? {
      PasteArrivalCapture.prepare(
        .init(tier: tier, pid: 42, takeID: takeID, bundleID: bundleID, payload: payload),
        capturedTarget: captured, restoringCapturedTimeoutTo: restore, ax: ax, scheduler: clock,
        report: { self.reports.append($0) }, log: { self.lines.append($0) })
    }
    /// The one landing registration the session made.
    var registration: PastedRegionFakeRegistration? { ax.landingRegistrations.last }
  }

  /// Unwraps a prepared session. Not `#require`: its expansion wants a Sendable value.
  private func prepared(_ session: PasteArrivalCapture?, sourceLocation: SourceLocation = #_sourceLocation)
    throws -> PasteArrivalCapture
  {
    guard let session else {
      Issue.record("expected a prepared session", sourceLocation: sourceLocation)
      throw NotPrepared()
    }
    return session
  }
  private struct NotPrepared: Error {}

  @Test("Only the three key-paste tiers are observed")
  func onlyKeyPasteTiers() {
    let rig = Rig()
    #expect(rig.prepare(tier: .axDirect) == nil)
    #expect(rig.prepare(tier: .clipboardOnly) == nil)
    #expect(rig.prepare(tier: .cgEvent) != nil)
    #expect(rig.prepare(tier: .appleScript) != nil)
    #expect(rig.prepare(tier: .menuPaste) != nil)
  }

  @Test("A stable field without the text: absent at 300 ms, one exact log line after the shadow")
  func deadlineAbsentLogLine() throws {
    let rig = Rig()
    let session = try prepared(rig.prepare())
    session.commit()
    rig.clock.advance(ms: 1_500)
    #expect(session.landing == .absent)
    #expect(
      rig.lines == [
        "PASTE_LANDING tier=cgevent observed=absent reason=absent app=com.apple.TextEdit "
          + "app_class=native host_exposed_focus=true manual_ax=false target_window=unknown "
          + "before_ms=0 resolve_ms=300 late_check=completed_no_hit"
      ])
    #expect(rig.reports.count == 1)
    #expect(rig.registration?.invalidated == 1, "torn down after reporting")
  }

  @Test("A value notification wakes a read: the new occurrence is found at once")
  func valueNotificationFinds() throws {
    let rig = Rig(after: "Hello send the draft")
    let session = try prepared(rig.prepare())
    session.commit()
    rig.registration?.fire(.valueChanged)
    #expect(session.landing == .found(.sameField))
    #expect(rig.clock.now == 0, "no deadline was needed")
    #expect(rig.lines.first?.hasSuffix("late_check=not_applicable") == true, "\(rig.lines)")
  }

  @Test("A focus notification between arm and commit still invalidates a negative")
  func notificationBeforeCommitIsKept() throws {
    let rig = Rig()
    let session = try prepared(rig.prepare())
    rig.registration?.fire(.focusedElementChanged)
    session.commit()
    rig.clock.advance(ms: 300)
    #expect(session.landing == .inconclusive(.focusChanged))
  }

  @Test("Cancel before commit: registration invalidated once, no decision, no log, late callbacks ignored")
  func cancelIsSilent() async throws {
    let rig = Rig()
    let session = try prepared(rig.prepare())
    session.cancelUnlessCommitted()
    session.cancelUnlessCommitted()
    rig.registration?.fire(.valueChanged)
    session.commit()
    rig.clock.advance(ms: 1_500)
    #expect(await session.landingDecision() == nil)
    #expect(session.phase == .finished)
    #expect(rig.registration?.invalidated == 1, "exactly once")
    #expect(rig.lines.isEmpty && rig.reports.isEmpty)
  }

  @Test("A terminated target outranks a frontmost change; a live target with another app in front is app_switched")
  func terminationBeforeSwitch() throws {
    let rig = Rig()
    let session = try prepared(rig.prepare())
    session.commit()
    rig.ax.runningPIDs = []
    rig.ax.frontmost = 7
    rig.clock.advance(ms: 300)
    #expect(session.landing == .inconclusive(.appTerminated))

    let other = Rig()
    let second = try prepared(other.prepare())
    second.commit()
    other.ax.frontmost = 7
    other.clock.advance(ms: 300)
    #expect(second.landing == .inconclusive(.appSwitched))
  }

  @Test("Nothing focused: only the application's focus notification, and no_target when it stays so")
  func noFocus() throws {
    let rig = Rig()
    rig.ax.focusedByApplication[42] = .noFocus
    rig.ax.focused[42] = .noFocus
    let session = try prepared(rig.prepare(captured: nil))
    #expect(rig.registration?.registeredNotifications == [.focusedElementChanged])
    session.commit()
    rig.clock.advance(ms: 1_500)
    #expect(session.landing == .noTarget)
    #expect(rig.lines.first?.contains("host_exposed_focus=false") == true)
  }

  @Test("A failed focus query and a secure field are cannot_read, never absent")
  func unreadableBefore() throws {
    let failed = Rig()
    failed.ax.focusedByApplication[42] = .queryFailed(.cannotComplete)
    let a = try prepared(failed.prepare())
    a.commit()
    failed.clock.advance(ms: 300)
    #expect(a.landing == .cannotRead(.baselineUnreadable))

    let secure = Rig()
    secure.ax.subroles["\(CFHash(PastedRegionFakeAX.field(42)))"] = .subrole("AXSecureTextField")
    let b = try prepared(secure.prepare())
    b.commit()
    secure.clock.advance(ms: 300)
    #expect(b.landing == .cannotRead(.baselineUnreadable))
    #expect(secure.ax.readCount == 0, "a secure field's text is never read")
  }

  @Test("A partial registration is inconclusive, and teardown invalidates what succeeded")
  func partialRegistrationIsInconclusive() throws {
    let rig = Rig()
    rig.ax.landingNotificationFailures = [.elementDestroyed]
    let session = try prepared(rig.prepare())
    session.commit()
    rig.clock.advance(ms: 300)
    #expect(session.landing == .inconclusive(.registrationIncomplete))
    #expect(rig.registration?.invalidated == 1)
  }

  @Test("A preparation budget spent at a nested read is budget_spent, not an unreadable field")
  func budgetExhaustedInPrepare() throws {
    let rig = Rig()
    rig.clock.tickPerNowRead = 150  // the fourth clock read finds the 500 ms budget spent
    let session = try prepared(rig.prepare())
    session.commit()
    rig.clock.advance(ms: 300)
    #expect(session.landing == .inconclusive(.budgetSpent))
  }

  @Test("The last registration spending the rest of the budget is budget_spent, not complete")
  func budgetSpentByTheLastCall() throws {
    let rig = Rig()
    rig.ax.afterLandingNotification = { kind in
      if kind == .focusedElementChanged { rig.clock.advance(ms: 600) }
    }
    let session = try prepared(rig.prepare())
    session.commit()
    rig.clock.advance(ms: 300)
    #expect(session.landing == .inconclusive(.budgetSpent))
    // Paired: the same preparation without the slow last call is an ordinary absent.
    let control = Rig()
    let clean = try prepared(control.prepare())
    clean.commit()
    control.clock.advance(ms: 300)
    #expect(clean.landing == .absent)
  }

  @Test("The delivery path's field handle gets its own timeout back, and only that handle")
  func capturedTimeoutRestored() throws {
    // 0.25, not production's 0.5: the budget itself installs 0.5 on a fresh preparation, so a
    // restore to 0.5 could not be told from no restore at all. The fake gives the captured and the
    // focused field one pid, so the check reads the LAST install on that pid.
    let fieldPid = Self.fieldPid
    for restore in [0.0, 0.25] {
      let rig = Rig()
      _ = try prepared(rig.prepare(restore: restore))
      let onField = rig.ax.timeoutsSet.filter { $0.0 == fieldPid }
      #expect(onField.count >= 2, "the budget bounded it, then it was put back")
      #expect(onField.last?.1 == restore, "restored to \(restore)")
    }
    // No captured field: no restore is written anywhere.
    let rig = Rig()
    _ = try prepared(rig.prepare(captured: nil, restore: 0.25))
    #expect(!rig.ax.timeoutsSet.contains { $0.1 == 0.25 })
  }

  @Test("Two overlapping sessions report independently")
  func overlappingSessions() throws {
    let rig = Rig()
    rig.ax.reads = [.text("Hello"), .text("Hello"), .text("Hello send the draft")]
    let first = try prepared(rig.prepare(takeID: "TAKE-A"))
    let firstRegistration = rig.registration
    first.commit()
    let second = try prepared(rig.prepare(takeID: "TAKE-B"))
    second.commit()
    #expect(first.context.takeID == "TAKE-A" && second.context.takeID == "TAKE-B")
    firstRegistration?.fire(.valueChanged)
    #expect(first.landing == .found(.sameField))
    rig.clock.advance(ms: 25)
    #expect(second.landing == .found(.sameField))
    #expect(rig.reports.map(\.takeID) == ["TAKE-A", "TAKE-B"])
    #expect(rig.lines.count == 2)
  }

  @Test("An unread manual-accessibility answer is other (or browser by bundle), never native")
  func appClassUnread() throws {
    // The application handle refuses its timeout, so the budget never asks the question.
    let slack = Rig()
    slack.ax.timeoutFailsFor = [Self.pid]
    let session = try prepared(slack.prepare(bundleID: "com.tinyspeck.slackmacgap"))
    #expect(session.appClass == .other)
    session.commit()
    slack.clock.advance(ms: 1_500)
    #expect(slack.lines.first?.contains("manual_ax=unknown") == true, "\(slack.lines)")
    let chrome = Rig()
    chrome.ax.timeoutFailsFor = [Self.pid]
    #expect(try prepared(chrome.prepare(bundleID: "com.google.Chrome")).appClass == .browser)
    // The call ran but its read failed: also unread.
    let failed = Rig()
    failed.ax.manualReadFails = [Self.pid]
    let failedSession = try prepared(failed.prepare(bundleID: "com.tinyspeck.slackmacgap"))
    #expect(failedSession.appClass == .other)
    failedSession.commit()
    failed.clock.advance(ms: 1_500)
    #expect(failed.lines.first?.contains("manual_ax=unknown") == true, "\(failed.lines)")
    // Paired: the same Slack session with the question answered "no" is native, as before.
    let answered = Rig()
    #expect(try prepared(answered.prepare(bundleID: "com.tinyspeck.slackmacgap")).appClass == .native)
  }

  @Test("The app class comes from the snapshot: browser first, then manual host, then native")
  func appClassFromSnapshot() throws {
    // Safari is a recognised browser and not a manual host; Chrome is both, and browser wins.
    let safari = Rig()
    #expect(try prepared(safari.prepare(bundleID: "com.apple.Safari")).appClass == .browser)
    let chrome = Rig()
    chrome.ax.manualHosts = [42]
    #expect(try prepared(chrome.prepare(bundleID: "com.google.Chrome")).appClass == .browser)
    // An unrecognised manual-accessibility host, and a native one.
    let slack = Rig()
    slack.ax.manualHosts = [42]
    let slackSession = try prepared(slack.prepare(bundleID: "com.tinyspeck.slackmacgap"))
    #expect(slackSession.appClass == .manualAccessibility)
    let textEdit = Rig()
    #expect(try prepared(textEdit.prepare()).appClass == .native)
    // Snapshotted: the host stops answering, another app comes forward; the class stands.
    slack.ax.manualHosts = []
    slack.ax.frontmost = 7
    #expect(slackSession.appClass == .manualAccessibility)
  }

  @Test("Selection ranges are UTF-16 and never clamped")
  func selectionRanges() {
    let text = "a😀b"  // a, then two UTF-16 units for the emoji, then b
    typealias C = PasteArrivalCapture
    #expect(C.selectedText(in: text, range: .range(location: 1, length: 2)) == "😀")
    #expect(C.selectedText(in: text, range: .range(location: 4, length: 0)) == "")
    #expect(C.selectedText(in: text, range: .range(location: 2, length: 1)) == nil, "splits the emoji")
    #expect(C.selectedText(in: text, range: .range(location: 0, length: 5)) == nil, "past the end")
    #expect(C.selectedText(in: text, range: .range(location: -1, length: 1)) == nil)
    #expect(C.selectedText(in: text, range: .range(location: 1, length: Int.max)) == nil, "overflow")
    #expect(C.selectedText(in: text, range: .unavailable) == nil)
  }
}
