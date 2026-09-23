import ApplicationServices
import EnviousWisprServices
import Foundation
import Testing

/// The arrival session (#3106 PR A): one reader per key paste, a landing decision at the first new
/// occurrence or at the deadline, a late-hit shadow for a potential miss, one report, and #996's
/// separately timed edit-watch capture. Driven by the scripted AX fake and the logical clock:
/// nothing here waits on wall time.
@MainActor
@Suite(.tags(.productOutcome))
struct PasteArrivalCaptureTests {
  let ax = PastedRegionFakeAX()
  let scheduler = PastedRegionFakeScheduler()
  let pid: pid_t = 42
  final class Reports { var list: [PasteArrivalObservation] = [] }
  let reports = Reports()
  var field: AXUIElement { PastedRegionFakeAX.field(pid) }

  init() {
    // The baseline asks the application for its focus; every later read asks by pid.
    ax.focusedByApplication[pid] = .element(PastedRegionFakeAX.field(pid))
    ax.focused[pid] = .element(PastedRegionFakeAX.field(pid))
    ax.reads = [.text("Hi ")]
    ax.selectedRange = .range(location: 3, length: 0)
  }

  func prepare(
    _ payload: String = "Sarah ", tier: PasteTier = .cgEvent, bundle: String? = "com.apple.TextEdit"
  ) throws -> PasteArrivalCapture {
    let reports = self.reports
    // Not `#require`: its expansion wants a Sendable value, and a session holds AX handles.
    guard
      let session = PasteArrivalCapture.prepare(
        .init(tier: tier, pid: pid, takeID: "take-1", bundleID: bundle, payload: payload),
        capturedTarget: nil, restoringCapturedTimeoutTo: 0, ax: ax, scheduler: scheduler,
        report: { reports.list.append($0) })
    else { throw NotPrepared() }
    return session
  }

  struct NotPrepared: Error {}

  /// Waits for a signal FROM THE SESSION (`arm` receives the one-shot `fire`). The fake clock
  /// drives behaviour; the wall-clock deadline only turns a signal that never comes into a loud
  /// failure instead of a hung suite.
  @MainActor
  static func awaitSignal(
    _ what: String, sourceLocation: SourceLocation = #_sourceLocation,
    arm: (@escaping @MainActor () -> Void) -> Void
  ) async {
    final class Once { var done = false }
    let once = Once()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let fire: @MainActor () -> Void = {
        guard !once.done else { return }
        once.done = true
        continuation.resume()
      }
      arm(fire)
      Task { @MainActor in
        // deadline-fallback: only reached when the subject never signals; normal runs resume first.
        try? await Task.sleep(for: .seconds(5))
        guard !once.done else { return }
        Issue.record("never signalled: \(what)", sourceLocation: sourceLocation)
        fire()
      }
    }
  }

  /// #996's answer, kept on the main actor: it holds AX handles, so it cannot leave through a
  /// `Task`'s value. `result()` waits for the session's own resolution, not for time.
  @MainActor
  final class EditProbe {
    private(set) var outcome: PastedRegionCaptureOutcome?
    private var resolved: (@MainActor () -> Void)?
    func finish(_ outcome: PastedRegionCaptureOutcome) {
      self.outcome = outcome
      resolved?()
    }
    func result() async -> PastedRegionCaptureOutcome {
      if outcome == nil {
        await PasteArrivalCaptureTests.awaitSignal("#996's request resolved") { fire in
          resolved = fire
        }
      }
      return outcome ?? .ended(.captureUnsupported)
    }
  }

  var registration: PastedRegionFakeRegistration? { ax.landingRegistrations.last }

  // MARK: Positives

  @Test(
    "a value notification wakes a read that finds the new occurrence at once; one report, all torn down"
  )
  func immediateHit() throws {
    let session = try prepare()
    #expect(session.registrationComplete)
    ax.reads = [.text("Hi Sarah ")]
    session.commit()
    registration?.fire(.valueChanged)
    #expect(session.landing == .found(.sameField))
    #expect(reports.list.count == 1)
    #expect(reports.list.first?.lateCheck == .notApplicable)
    #expect(reports.list.first?.resolveMs == 0)
    #expect(registration?.invalidated == 1)
    #expect(scheduler.pending.isEmpty, "no timer outlives the decision")
  }

  @Test("without notifications the 25 ms poll finds the paste")
  func hitAfterPolling() throws {
    let session = try prepare()
    ax.reads = [.text("Hi "), .text("Hi Sarah ")]
    session.commit()
    scheduler.advance(ms: 25)
    #expect(session.landing == nil)
    scheduler.advance(ms: 25)
    #expect(session.landing == .found(.sameField))
    #expect(reports.list.map(\.resolveMs) == [50])
  }

  @Test("an identical chunk pasted twice is found by its count, not by its words")
  func repeatedChunkIsFound() throws {
    ax.reads = [.text("thanks ")]
    ax.selectedRange = .range(location: 7, length: 0)
    let session = try prepare("thanks ")
    ax.reads = [.text("thanks thanks ")]
    session.commit()
    scheduler.advance(ms: 25)
    #expect(session.landing == .found(.sameField))
  }

  @Test("a partial registration can still find a positive")
  func partialRegistrationFindsAPositive() throws {
    ax.landingNotificationFailures = [.elementDestroyed]
    let session = try prepare()
    #expect(session.registrationComplete == false)
    ax.reads = [.text("Hi Sarah ")]
    session.commit()
    scheduler.advance(ms: 25)
    #expect(session.landing == .found(.sameField))
  }

  // MARK: Negatives and their guards

  @Test(
    "a stable field without the text is absent at 300 ms, then shadowed to 1.5 s before one report")
  func stableMissShadowsThenReports() throws {
    let session = try prepare()
    session.commit()
    scheduler.advance(ms: 299)
    #expect(session.landing == nil)
    scheduler.advance(ms: 1)
    #expect(session.landing == .absent)
    #expect(session.phase == .shadowing)
    #expect(reports.list.isEmpty, "a potential miss reports only after its shadow")
    scheduler.advance(ms: 1_200)
    #expect(reports.list.count == 1)
    #expect(reports.list.first?.landing == .absent)
    #expect(reports.list.first?.lateCheck == .completedNoHit)
    #expect(reports.list.first?.resolveMs == 300)
    #expect(scheduler.pending.isEmpty)
  }

  @Test("text that appears after the decision is a late hit; the decision stands")
  func lateHitAfterTheDecision() throws {
    let session = try prepare()
    session.commit()
    scheduler.advance(ms: 300)
    #expect(session.landing == .absent)
    ax.reads = [.text("Hi Sarah ")]
    scheduler.advance(ms: 25)
    #expect(session.landing == .absent)
    #expect(reports.list.map(\.lateCheck) == [.found(ms: 325)])
  }

  @Test(
    "an incomplete registration, a focus change or a destroyed element makes a negative inconclusive"
  )
  func negativesNeedAnIntactComparison() throws {
    ax.landingNotificationFailures = [.elementDestroyed]
    let partial = try prepare()
    partial.commit()
    scheduler.advance(ms: 300)
    #expect(partial.landing == .inconclusive(.registrationIncomplete))

    ax.landingNotificationFailures = []
    let focus = try prepare()
    focus.commit()
    registration?.fire(.focusedElementChanged)
    scheduler.advance(ms: 300)
    #expect(focus.landing == .inconclusive(.focusChanged))

    let destroyed = try prepare()
    destroyed.commit()
    registration?.fire(.elementDestroyed)
    scheduler.advance(ms: 300)
    #expect(destroyed.landing == .inconclusive(.elementDestroyed))
  }

  @Test("an unstable final read is inconclusive, never absent")
  func unstableIsNotAbsent() throws {
    let session = try prepare()
    ax.reads = [.unstable]
    session.commit()
    scheduler.advance(ms: 300)
    #expect(session.landing == .inconclusive(.unstable))
    #expect(reports.list.count == 1, "not a miss: reported at once, no shadow")
  }

  @Test(
    "with the text already there, an unchanged count needs a selection that rules out an identical replacement"
  )
  func nonzeroBaselineNeedsTheSelection() throws {
    ax.reads = [.text("thanks ")]
    ax.selectedRange = .range(location: 7, length: 0)
    let caret = try prepare("thanks ")
    caret.commit()
    scheduler.advance(ms: 300)
    #expect(caret.landing == .absent)

    ax.selectedRange = .unavailable
    let unknown = try prepare("thanks ")
    unknown.commit()
    scheduler.advance(ms: 300)
    #expect(unknown.landing == .inconclusive(.selectionUnavailable))

    ax.selectedRange = .range(location: 0, length: 7)
    let over = try prepare("thanks ")
    over.commit()
    scheduler.advance(ms: 300)
    #expect(over.landing == .inconclusive(.selectionOverlap))
  }

  @Test("nothing focused before and throughout is no_target; something focused later is not")
  func noTarget() throws {
    ax.focusedByApplication[pid] = .noFocus
    ax.focused[pid] = .noFocus
    let none = try prepare()
    #expect(none.registrationComplete)
    none.commit()
    scheduler.advance(ms: 300)
    #expect(none.landing == .noTarget)

    let moved = try prepare()
    ax.focused[pid] = .element(field)
    moved.commit()
    scheduler.advance(ms: 300)
    #expect(moved.landing == .inconclusive(.moved))
  }

  @Test(
    "an unknown manual-accessibility answer, a secure field, or an unreadable baseline never makes a negative"
  )
  func unknownEvidenceIsNotANegative() throws {
    ax.manualReadFails = [pid]
    let unknown = try prepare()
    unknown.commit()
    scheduler.advance(ms: 300)
    #expect(unknown.landing == .inconclusive(.manualAccessibilityUnknown))

    ax.manualReadFails = []
    ax.subroles["\(CFHash(field))"] = .subrole(kAXSecureTextFieldSubrole as String)
    let secure = try prepare()
    secure.commit()
    scheduler.advance(ms: 300)
    #expect(secure.landing == .cannotRead(.baselineUnreadable))
  }

  @Test("only the same field through the same reader proves a new occurrence")
  func positivesNeedTheSameFieldAndReader() throws {
    // Another field already holding the phrase proves nothing.
    let other = AXUIElementCreateApplication(99)
    let moved = try prepare()
    ax.focused[pid] = .element(other)
    ax.reads = [.text("Sarah ")]
    moved.commit()
    scheduler.advance(ms: 300)
    #expect(moved.landing == .inconclusive(.moved))

    // No readable baseline: an occurrence seen later may have been there all along.
    ax.focused[pid] = .element(field)
    ax.focusedByApplication[pid] = .queryFailed(.cannotComplete)
    let blind = try prepare()
    blind.commit()
    scheduler.advance(ms: 300)
    #expect(blind.landing == .cannotRead(.baselineUnreadable))

    // The same field read through the other reader is not comparable.
    ax.focusedByApplication[pid] = .element(field)
    ax.reads = [.text("Hi ")]
    let changedReader = try prepare()
    ax.reads = [.absent]
    ax.counts = [.count(9)]
    ax.rangeReads = [.text("Hi Sarah ")]
    changedReader.commit()
    scheduler.advance(ms: 300)
    #expect(changedReader.landing == .inconclusive(.readerChanged))
  }

  @Test("an unrelated edit with the phrase still absent is inconclusive, not absent")
  func unrelatedEditIsNotAbsent() throws {
    let session = try prepare()
    ax.reads = [.text("Bye ")]
    session.commit()
    scheduler.advance(ms: 300)
    #expect(session.landing == .inconclusive(.valueChanged))
  }

  @Test("a saved selection is validated before any arithmetic")
  func selectionIsValidated() throws {
    ax.reads = [.text("thanks ")]
    for bad: PastedRegionSelectedRange in [
      .range(location: Int.max, length: 1), .range(location: -1, length: 0),
      .range(location: 0, length: -1), .range(location: 50, length: 0),
    ] {
      ax.selectedRange = bad
      let session = try prepare("thanks ")
      session.commit()
      scheduler.advance(ms: 300)
      #expect(session.landing == .inconclusive(.selectionUnavailable), "\(bad)")
    }
  }

  @Test("no focus with an unknown manual-accessibility answer is not no_target")
  func noFocusNeedsAKnownHost() throws {
    ax.focusedByApplication[pid] = .noFocus
    ax.focused[pid] = .noFocus
    ax.manualReadFails = [pid]
    let session = try prepare(bundle: "com.google.Chrome")
    session.commit()
    scheduler.advance(ms: 300)
    #expect(session.landing == .inconclusive(.manualAccessibilityUnknown))
  }

  @Test("a host that needs the opt-in is never no_target, whether or not its opt-in succeeds")
  func noFocusOnAManualHostIsNeverNoTarget() throws {
    ax.focusedByApplication[pid] = .noFocus
    ax.focused[pid] = .noFocus
    ax.manualHosts = [pid]
    for succeeds in [false, true] {
      ax.enableSucceeds = succeeds
      reports.list = []
      let session = try prepare(bundle: "com.google.Chrome")
      session.commit()
      scheduler.advance(ms: 300)
      #expect(session.landing == .inconclusive(.manualAccessibilityHost), "opt-in \(succeeds)")
      #expect(reports.list.count == 1, "not a miss: reported at once, no shadow")
    }
    // The control: a host that needs no opt-in, with the same answers, is no_target.
    ax.manualHosts = []
    let native = try prepare()
    native.commit()
    scheduler.advance(ms: 300)
    #expect(native.landing == .noTarget)
  }

  @Test(
    "permission lost by the final read is cannot_read/permission_lost behind every comparison doubt"
  )
  func permissionLossIsNeverHidden() throws {
    // Each doubt alone (trust intact) is its own inconclusive; with trust gone it is permission_lost.
    let doubts: [(String, PasteArrivalLanding, () -> Void)] = [
      (
        "manual host, nothing focused", .inconclusive(.manualAccessibilityHost),
        {
          ax.focusedByApplication[pid] = .noFocus
          ax.focused[pid] = .noFocus
          ax.manualHosts = [pid]
        }
      ),
      (
        "unknown host, nothing focused", .inconclusive(.manualAccessibilityUnknown),
        {
          ax.focusedByApplication[pid] = .noFocus
          ax.focused[pid] = .noFocus
          ax.manualReadFails = [pid]
        }
      ),
      (
        "incomplete registration", .inconclusive(.registrationIncomplete),
        {
          ax.landingNotificationFailures = [.elementDestroyed]
        }
      ),
      ("spent budget", .inconclusive(.budgetSpent), { scheduler.tickPerNowRead = 150 }),
    ]
    for (name, doubtAlone, arrange) in doubts {
      for losesTrust in [false, true] {
        ax.trusted = true
        ax.focusedByApplication[pid] = .element(field)
        ax.focused[pid] = .element(field)
        ax.manualHosts = []
        ax.manualReadFails = []
        ax.landingNotificationFailures = []
        arrange()
        let session = try prepare()
        scheduler.tickPerNowRead = 0
        session.commit()
        if losesTrust { ax.trusted = false }
        scheduler.advance(ms: 300)
        let expected = losesTrust ? .cannotRead(.permissionLost) : doubtAlone
        #expect(session.landing == expected, "\(name), trust lost: \(losesTrust)")
      }
    }
  }

  @Test("a destination lost during the shadow censors the late check instead of claiming no hit")
  func shadowLossCensors() throws {
    let session = try prepare()
    session.commit()
    scheduler.advance(ms: 300)
    #expect(session.landing == .absent)
    registration?.fire(.focusedElementChanged)
    scheduler.advance(ms: 1_200)
    #expect(reports.list.map(\.lateCheck) == [.censored])
    #expect(reports.list.first?.landing == .absent, "the decision stands")
  }

  @Test("a shadow read that cannot finish counting censors the late check")
  func incompleteShadowReadCensors() throws {
    // A text whose count can run out of budget on an adversarial field: 100 "a" then "c".
    let payload = String(repeating: "a", count: 100) + "c"
    let session = try prepare(payload)
    session.commit()
    scheduler.advance(ms: 300)
    #expect(session.landing == .absent)
    // One shadow read of the same element through the same reader whose count spends its budget
    // (about 19,900 starts x 101 units), then the ordinary field again.
    ax.reads = [.text(String(repeating: "a", count: 19_999) + "b"), .text("Hi ")]
    scheduler.advance(ms: 1_200)
    #expect(reports.list.map(\.lateCheck) == [.censored])
  }

  @Test("a #996 target captured before cancellation is not handed out after it")
  func cancelledSessionHandsOutNoCachedTarget() async throws {
    let session = try prepare()
    ax.reads = [.text("Hi Sarah ")]
    session.commit()
    guard case .captured = await startEditRequest(session).result() else {
      Issue.record("expected a capture before cancellation")
      return
    }
    session.cancel()
    let reads = ax.readCount
    let again = await session.editWatchCapture(pastedAtMs: 0)
    #expect(again == .ended(.captureUnsupported))
    #expect(ax.readCount == reads)
  }

  // MARK: Cancellation and stale callbacks

  @Test(
    "cancel before commit is silent; after commit it is inconclusive/cancelled; after the decision it keeps it"
  )
  func cancellation() async throws {
    let unwritten = try prepare()
    unwritten.cancelUnlessCommitted()
    #expect(await unwritten.landingDecision() == nil)
    #expect(reports.list.isEmpty)
    #expect(registration?.invalidated == 1)

    let early = try prepare()
    early.commit()
    early.cancel()
    #expect(early.landing == .inconclusive(.cancelled))
    #expect(reports.list.last?.lateCheck == .censored)

    let late = try prepare()
    late.commit()
    scheduler.advance(ms: 300)
    late.cancel()
    #expect(late.landing == .absent)
    #expect(reports.list.last?.lateCheck == .censored)
    #expect(reports.list.count == 2, "one report per committed session")
    late.cancel()
    #expect(reports.list.count == 2)
  }

  @Test("callbacks queued before teardown do nothing")
  func staleCallbacks() throws {
    let session = try prepare()
    ax.reads = [.text("Hi Sarah ")]
    session.commit()
    registration?.fire(.valueChanged)
    let reads = ax.readCount
    registration?.fire(.valueChanged)
    registration?.fire(.focusedElementChanged)
    scheduler.advance(ms: 2_000)
    #expect(ax.readCount == reads)
    #expect(reports.list.count == 1)
  }

  @Test("every waiter gets the same decision")
  func waitersShareTheDecision() async throws {
    let session = try prepare()
    session.commit()
    final class Count { var joined = 0 }
    let count = Count()
    await Self.awaitSignal("two landing waiters joined") { fire in
      session.onLandingWaiter = {
        count.joined += 1
        if count.joined == 2 { fire() }
      }
      Task { _ = await session.landingDecision() }
      Task { _ = await session.landingDecision() }
    }
    let first = Task { await session.landingDecision() }
    scheduler.advance(ms: 300)
    #expect(await first.value == .absent)
    #expect(await session.landingDecision() == .absent)
  }

  // MARK: #996's edit-watch capture

  /// Starts #996's request and returns once its first read has happened, so the test can move
  /// the clock while the request is still waiting.
  func startEditRequest(_ session: PasteArrivalCapture, pastedAtMs: Int = 0) async -> EditProbe {
    let probe = EditProbe()
    await Self.awaitSignal("#996's first read") { fire in
      session.onEditAttempt = fire
      Task { @MainActor in probe.finish(await session.editWatchCapture(pastedAtMs: pastedAtMs)) }
    }
    return probe
  }

  @Test("#996 gets the new occurrence even when it asks long after the landing session ended")
  func editRequestAfterTheSession() async throws {
    let session = try prepare()
    ax.reads = [.text("Hi Sarah ")]
    session.commit()
    scheduler.advance(ms: 25)
    #expect(session.phase == .finished)
    scheduler.advance(ms: 2_000)
    let probe = await startEditRequest(session, pastedAtMs: 7)
    guard case .captured(let target) = await probe.result() else {
      Issue.record("expected captured")
      return
    }
    #expect(target.renderedText == "Sarah ")
    #expect(target.anchors == PastedRegionAnchors(before: "Hi ", after: ""))
    #expect(target.pastedAtMs == 7)
  }

  @Test("#996's grace runs from its own request: not there yet, then there")
  func editRequestRetriesOnItsOwnTimer() async throws {
    let session = try prepare()
    session.commit()
    scheduler.advance(ms: 1_600)  // the landing session has decided and shadowed out
    #expect(session.phase == .finished)
    let probe = await startEditRequest(session)
    scheduler.advance(ms: 1_000)
    ax.reads = [.text("Hi Sarah ")]
    scheduler.advance(ms: 25)
    guard case .captured = await probe.result() else {
      Issue.record("expected captured within the request's own 1.5 s")
      return
    }
  }

  @Test("#996's grace ends 1.5 s after its request with the not-found answer")
  func editRequestGivesUp() async throws {
    let session = try prepare()
    session.commit()
    let probe = await startEditRequest(session)
    scheduler.advance(ms: 1_500)
    let outcome = await probe.result()
    #expect(outcome == .ended(.dictatedTextNotFound))
  }

  @Test(
    "#996 watches only the occurrence PROVEN new: the pre-write selection proves it, a caret never does"
  )
  func editRequestPicksOnlyTheNewOccurrence() async throws {
    // Where the paste went is known (the caret was at the end), so the new occurrence is [7, 14),
    // even with the post-paste caret parked on the OLD one at 7.
    ax.reads = [.text("thanks ")]
    ax.selectedRange = .range(location: 7, length: 0)
    let proven = try prepare("thanks ")
    ax.reads = [.text("thanks thanks ")]
    proven.commit()
    guard case .captured(let target) = await startEditRequest(proven).result() else {
      Issue.record("expected the proven new occurrence")
      return
    }
    #expect(target.anchors == PastedRegionAnchors(before: "thanks ", after: ""))

    // Without the pre-write selection the two alignments disagree ([7,14) or [0,7)): ambiguous.
    ax.reads = [.text("thanks ")]
    ax.selectedRange = .unavailable
    let unproven = try prepare("thanks ")
    ax.reads = [.text("thanks thanks ")]
    unproven.commit()
    let ambiguous = await startEditRequest(unproven).result()
    #expect(ambiguous == .ended(.anchorAmbiguous))
  }

  @Test("cancellation ends #996's request: before it is made, and while it is retrying")
  func cancellationEndsTheEditRequest() async throws {
    let finished = try prepare()
    ax.reads = [.text("Hi Sarah ")]
    finished.commit()
    scheduler.advance(ms: 25)
    #expect(finished.phase == .finished)
    finished.cancel()
    let reads = ax.readCount
    let refused = await finished.editWatchCapture(pastedAtMs: 0)
    #expect(refused == .ended(.captureUnsupported))
    #expect(ax.readCount == reads, "a cancelled session reads nothing for #996")

    ax.reads = [.text("Hi ")]
    let retrying = try prepare()
    retrying.commit()
    let probe = await startEditRequest(retrying)
    scheduler.advance(ms: 50)
    retrying.cancel()
    let outcome = await probe.result()
    #expect(outcome == .ended(.captureUnsupported))
  }

  @Test("#996 withdrawing its request stops its reads at once; the landing shadow and report go on")
  func withdrawnEditRequestStopsReading() async throws {
    let session = try prepare()
    session.commit()
    scheduler.advance(ms: 300)
    #expect(session.phase == .shadowing)
    let probe = await startEditRequest(session)
    final class Count { var attempts = 0 }
    let count = Count()
    session.onEditAttempt = { count.attempts += 1 }
    scheduler.advance(ms: 50)
    let before = count.attempts
    #expect(before > 0, "the request is retrying")
    session.cancelEditWatchCapture()
    #expect(await probe.result() == .ended(.captureUnsupported))
    scheduler.advance(ms: 500)
    #expect(count.attempts == before, "no read for a withdrawn request")
    session.cancelEditWatchCapture()  // idempotent
    scheduler.advance(ms: 1_000)
    #expect(reports.list.map(\.lateCheck) == [.completedNoHit], "the landing report is untouched")
  }

  @Test(
    "a failed opt-in is asked again at a later read, at most three times, and never after it succeeds"
  )
  func failedOptInIsRetriedBounded() throws {
    ax.manualHosts = [pid]
    ax.enableSucceeds = false
    let recovers = try prepare()
    recovers.commit()
    scheduler.advance(ms: 25)
    #expect(ax.enableCalls == [pid])
    ax.enableSucceeds = true
    scheduler.advance(ms: 25)
    #expect(ax.enableCalls == [pid, pid], "asked again after the failure")
    scheduler.advance(ms: 100)
    #expect(ax.enableCalls == [pid, pid], "never again once it succeeded")
    recovers.cancel()

    ax.enableCalls = []
    ax.enableSucceeds = false
    let busy = try prepare()
    busy.commit()
    scheduler.advance(ms: 300)
    #expect(ax.enableCalls == [pid, pid, pid], "three bounded attempts, then no more")
    busy.cancel()
  }

  // MARK: Tier 1 (AX direct): #996 only

  func editOnly(_ payload: String = "Sarah ") -> PasteArrivalCapture {
    PasteArrivalCapture.editOnly(
      pid: pid, bundleID: "com.apple.TextEdit", payload: payload, ax: ax, scheduler: scheduler)
  }

  @Test(
    "a Tier 1 session observes no landing: no AX work, no timer, no decision, no report, nothing to await"
  )
  func editOnlyObservesNoLanding() async throws {
    let session = editOnly()
    #expect(session.phase == .finished)
    #expect(ax.readCount == 0 && ax.landingCalls.isEmpty && ax.landingRegistrations.isEmpty)
    #expect(ax.selectedRangeReads == 0 && ax.enableCalls.isEmpty)
    #expect(scheduler.scheduledCount == 0, "no deadline, poll or shadow")
    #expect(await session.landingDecision() == nil)
    await session.terminated()  // returns at once: the wiring's owner task holds nothing
    session.cancel()
    #expect(reports.list.isEmpty && scheduler.scheduledCount == 0)
  }

  @Test(
    "a Tier 1 session gives #996 its capture: opt-in at the request, a late arrival, the paste time kept"
  )
  func editOnlyCapturesForTheWatch() async throws {
    ax.manualHosts = [pid]
    ax.reads = [.text("Hi ")]
    let session = editOnly()
    #expect(ax.enableCalls.isEmpty, "nothing before #996 asks")
    let probe = await startEditRequest(session, pastedAtMs: 9)
    #expect(ax.enableCalls == [pid], "opted in once, at #996's first read")
    ax.reads = [.text("Hi Sarah ")]
    scheduler.advance(ms: 25)
    guard case .captured(let target) = await probe.result() else {
      Issue.record("expected captured")
      return
    }
    #expect(target.renderedText == "Sarah ")
    #expect(target.pastedAtMs == 9)
    #expect(target.isManualAccessibilityHost)
    #expect(ax.enableCalls == [pid])
  }

  @Test("a Tier 1 session asks about manual accessibility only behind an installed timeout")
  func editOnlyManualQueryIsBounded() async throws {
    ax.manualHosts = [pid]
    ax.timeoutFailsFor = [pid]
    let refused = await startEditRequest(editOnly()).result()
    #expect(refused == .ended(.captureUnsupported), "the reader's own bounded failure")
    #expect(ax.manualQueries.isEmpty && ax.enableCalls.isEmpty, "no unbounded query, no opt-in")

    ax.timeoutFailsFor = []
    ax.reads = [.text("Hi Sarah ")]
    let timeoutsBefore = ax.timeoutsSet.count
    guard case .captured = await startEditRequest(editOnly()).result() else {
      Issue.record("expected captured")
      return
    }
    #expect(ax.manualQueries.first == pid, "asked once the bound is in place")
    let first = ax.timeoutsSet.dropFirst(timeoutsBefore).first
    #expect(
      first?.0 == pid && first?.1 == PasteService.axMessagingTimeoutSeconds, "the bound comes first"
    )
  }

  @Test(
    "a Tier 1 session has no baseline: one occurrence is watched, two are ambiguous, none times out at 1.5 s"
  )
  func editOnlyWithoutABaseline() async throws {
    ax.reads = [.text("thanks thanks ")]
    let twice = await startEditRequest(editOnly("thanks ")).result()
    #expect(twice == .ended(.anchorAmbiguous))

    ax.reads = [.text("Hi ")]
    let missing = await startEditRequest(editOnly())
    scheduler.advance(ms: 1_475)
    #expect(missing.outcome == nil, "still inside the request's own 1.5 s")
    scheduler.advance(ms: 25)
    #expect(await missing.result() == .ended(.dictatedTextNotFound))
  }

  // MARK: Preparation

  @Test(
    "only the three key-paste tiers are observed; neither preparation nor commit opts a host in")
  func preparation() throws {
    #expect(
      PasteArrivalCapture.prepare(
        .init(tier: .axDirect, pid: pid, takeID: nil, bundleID: nil, payload: "x"),
        capturedTarget: nil, restoringCapturedTimeoutTo: 0, ax: ax, scheduler: scheduler,
        report: { _ in }) == nil)
    ax.manualHosts = [pid]
    let session = try prepare()
    #expect(ax.enableCalls == [], "the baseline reads the host as it is")
    session.commit()
    #expect(ax.enableCalls == [], "commit does no AX work: it runs before the restore is scheduled")
    scheduler.advance(ms: 25)
    #expect(ax.enableCalls == [pid], "opted in once, at the first read after dispatch")
    scheduler.advance(ms: 100)
    #expect(ax.enableCalls == [pid], "never per read")
  }
}
