import EnviousWisprCore
import Foundation
import Testing

import EnviousWisprServices

/// #1631 — the hands-free publication gate.
///
/// A push-to-talk press that produces no recording must never publish hands-free
/// state, and must leave no bookkeeping behind for the next press to trip over.
/// A genuine double-tap must publish exactly once, whichever order acceptance and
/// the second press arrive in.
///
/// Every case drives the REAL Carbon entry point with the physical key sequence,
/// including the key-up between key-downs. `handleRecordPress` returns early on
/// `guard !isModifierHeld` (`HotkeyService.swift:225-227`), so a "press, press
/// again" test that omits the release never reaches the double-press branch and
/// would pass for the wrong reason.
///
/// Ordering is signal-based throughout: the injected start callback parks on a
/// continuation the test resolves, so "before acceptance" and "after acceptance"
/// are deterministic rather than raced. No sleeps, no clocks.
@MainActor
@Suite struct HotkeyHandsFreeLockGateTests {

  // `HotkeyID` raw values are private to `HotkeyService`; mirror them here.
  private let toggleID: UInt32 = 1
  private let cancelID: UInt32 = 3

  /// Synchronous telemetry spy — records every sink call on the main actor.
  @MainActor final class Spy {
    var presses: [String] = []
    var lockDecisions: [(committed: Bool, reason: String)] = []

    var sink: HotkeyTelemetrySink {
      HotkeyTelemetrySink(
        registrationFailed: { _, _, _, _ in },
        pressed: { [weak self] _, _, _, action in self?.presses.append(action) },
        lockResolved: { [weak self] committed, reason in
          self?.lockDecisions.append((committed, reason))
        })
    }
  }

  /// Drives the start callback under test control: the test decides WHAT each
  /// start reports and WHEN, so "before acceptance" and "after acceptance" are
  /// deterministic rather than raced.
  ///
  /// Continuations are keyed per CALL, not stored in a single slot. A single slot
  /// silently loses the first press's continuation when a second press starts —
  /// and `resolve` would then early-return, making every assertion vacuous
  /// against a service that never reconciled anything. (That bug produced 11
  /// green-looking-but-meaningless failures on the first run of this suite.)
  @MainActor final class StartDriver {
    private var pendingByCall: [Int: CheckedContinuation<RecordingStartOutcome, Never>] = [:]
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var resolvedCount = 0
    private var resolvedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var enteredCount = 0

    /// Wired to `HotkeyService.onStartResolvedForTesting`. The service fires this
    /// after `resolveStart` has run to completion on EVERY path, including the
    /// dropped-stale-result guard — which is the only exact completion signal.
    /// The callback's own return is one step too early: `resolveStart` runs after
    /// it. (The independent whole-diff review caught that; the earlier version
    /// passed by scheduling luck, not by construction.)
    func noteServiceResolved() {
      resolvedCount += 1
      for waiter in resolvedWaiters { waiter.resume() }
      resolvedWaiters.removeAll()
    }

    var handler: @MainActor () async -> RecordingStartOutcome {
      { [weak self] in
        guard let self else { return .noRecording }
        self.enteredCount += 1
        let call = self.enteredCount
        for waiter in self.entryWaiters { waiter.resume() }
        self.entryWaiters.removeAll()
        let outcome = await withCheckedContinuation { continuation in
          self.pendingByCall[call] = continuation
        }
        return outcome
      }
    }

    /// Park until the Nth start callback has actually been entered. Without this
    /// the service's start `Task` may not have run yet, so there is nothing to
    /// resolve and `resolve` would silently no-op.
    private func waitForEntry(call: Int) async {
      while enteredCount < call {
        await withCheckedContinuation { continuation in
          entryWaiters.append(continuation)
        }
      }
    }

    private func waitForResolution(count: Int) async {
      while resolvedCount < count {
        await withCheckedContinuation { continuation in
          resolvedWaiters.append(continuation)
        }
      }
    }

    /// Resolve the Nth start and return only once the service has reconciled it.
    ///
    /// Deliberately NOT `await Task.yield()`, and deliberately not the callback's
    /// own return either: both are guesses that the service reconciled. This waits
    /// on the service's own post-`resolveStart` signal. Two earlier versions of
    /// this driver were wrong in exactly this way — one made all eleven assertions
    /// vacuous, the other passed only by scheduling luck.
    func resolve(call: Int = 1, _ outcome: RecordingStartOutcome) async {
      await waitForEntry(call: call)
      guard let continuation = pendingByCall.removeValue(forKey: call) else {
        Issue.record("start callback \(call) entered without a pending continuation")
        return
      }
      let target = resolvedCount + 1
      continuation.resume(returning: outcome)
      await waitForResolution(count: target)
    }
  }

  /// Manual clock. The 500ms double-press window is measured in real elapsed
  /// time, so a suite that awaits between presses is at the mercy of scheduler
  /// load: under parallel test execution an await can outlast the window and the
  /// second press silently takes the stop or fresh-start branch instead of the
  /// lock branch. Every case here pins the clock so the branch under test is the
  /// branch that runs, regardless of machine load.
  @MainActor final class ManualClock {
    private(set) var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(ms: Int) { now = now.addingTimeInterval(Double(ms) / 1000.0) }
  }

  private func makeService(
    _ spy: Spy, driver: StartDriver? = nil, clock: ManualClock
  ) -> HotkeyService {
    let service = HotkeyService(telemetry: spy.sink, now: { clock.now })
    service.onStartResolvedForTesting = { driver?.noteServiceResolved() }
    service.recordingMode = .pushToTalk
    // keyCode 0 ('A') is a chord key, so no NSEvent monitor is involved.
    service.toggleKeyCode = 0
    return service
  }

  private func down(_ service: HotkeyService) {
    service.handleCarbonHotkey(id: toggleID, isRelease: false)
  }

  private func up(_ service: HotkeyService) {
    service.handleCarbonHotkey(id: toggleID, isRelease: true)
  }

  // MARK: - The reported bug

  @Test("a refused start never becomes a hands-free lock, and the next press starts fresh")
  func fastRefusalDoesNotLock() async {
    let spy = Spy()
    let clock = ManualClock()
    let driver = StartDriver()
    let service = makeService(spy, driver: driver, clock: clock)
    var published = 0
    service.onStartRecording = driver.handler
    service.onLockRequested = { _ in
      published += 1
      return .published
    }

    down(service)
    up(service)
    await driver.resolve(.noRecording)  // the cold-engine refusal, class B timing
    down(service)  // inside the original 500ms window

    // The second press must be a FRESH start, not a double-press lock.
    #expect(spy.presses == ["start", "start"])
    #expect(published == 0)
    #expect(service.isRecordingLocked == false)
    // A refusal that lands before any hands-free intent was recorded has no lock
    // decision to report.
    #expect(spy.lockDecisions.isEmpty)

    // The fresh start above parked a second checked continuation; resolve it so
    // neither it nor its task outlives the test.
    await driver.resolve(call: 2, .noRecording)
  }

  @Test("a refusal arriving after the double-press still publishes nothing")
  func slowRefusalDoesNotLock() async {
    let spy = Spy()
    let clock = ManualClock()
    let driver = StartDriver()
    let service = makeService(spy, driver: driver, clock: clock)
    var published = 0
    service.onStartRecording = driver.handler
    service.onLockRequested = { _ in
      published += 1
      return .published
    }

    down(service)
    up(service)
    down(service)  // double-press: records INTENT, must not publish yet
    #expect(published == 0, "intent must not publish before the start is accepted")
    await driver.resolve(.noRecording)  // class C timing: prewarm failed late

    #expect(published == 0)
    #expect(service.isRecordingLocked == false)
    #expect(spy.lockDecisions.count == 1)
    #expect(spy.lockDecisions.first?.committed == false)
    #expect(spy.lockDecisions.first?.reason == "start_produced_no_recording")
  }

  // MARK: - Two-way controls: a genuine double-tap must still work

  @Test("acceptance before the second press publishes exactly once")
  func acceptanceThenDoublePressPublishesOnce() async {
    let spy = Spy()
    let clock = ManualClock()
    let driver = StartDriver()
    let service = makeService(spy, driver: driver, clock: clock)
    var published = 0
    var askedAbout: [String] = []
    service.onStartRecording = driver.handler
    service.onLockRequested = { sessionID in
      askedAbout.append(sessionID)
      published += 1
      return .published
    }

    down(service)
    await driver.resolve(.recording("S1"))
    #expect(published == 0, "acceptance alone must not publish — the user has not double-tapped")
    up(service)
    down(service)

    #expect(published == 1)
    #expect(askedAbout == ["S1"])
    #expect(service.isRecordingLocked)
    #expect(spy.lockDecisions.count == 1)
    #expect(spy.lockDecisions.first?.committed == true)
    #expect(spy.lockDecisions.first?.reason == "published")
  }

  @Test("the second press before acceptance publishes exactly once, on acceptance")
  func doublePressThenAcceptancePublishesOnce() async {
    let spy = Spy()
    let clock = ManualClock()
    let driver = StartDriver()
    let service = makeService(spy, driver: driver, clock: clock)
    var published = 0
    var askedAbout: [String] = []
    service.onStartRecording = driver.handler
    service.onLockRequested = { sessionID in
      askedAbout.append(sessionID)
      published += 1
      return .published
    }

    down(service)
    up(service)
    down(service)
    #expect(published == 0, "publication must wait for acceptance")
    await driver.resolve(.recording("S2"))

    #expect(published == 1, "deferred, not lost")
    #expect(askedAbout == ["S2"])
    #expect(service.isRecordingLocked)
  }

  // MARK: - The case that chose this design

  @Test("a replacement session cannot inherit the accepted session's lock")
  func mismatchedSessionDoesNotPublish() async {
    let spy = Spy()
    let clock = ManualClock()
    let driver = StartDriver()
    let service = makeService(spy, driver: driver, clock: clock)
    var published = 0
    // The controller's real shape: publish only when the running session is the
    // one this press accepted. Here a DIFFERENT session is running by then.
    service.onStartRecording = driver.handler
    service.onLockRequested = { sessionID in
      guard sessionID == "S-running" else { return .notLockable }
      published += 1
      return .published
    }

    down(service)
    up(service)
    down(service)
    await driver.resolve(.recording("S-accepted"))

    #expect(published == 0)
    #expect(service.isRecordingLocked == false, "a rejected publication cleans up")
    #expect(spy.lockDecisions.count == 1)
    #expect(spy.lockDecisions.first?.reason == "not_lockable_at_publication")

    // And the next eligible press starts fresh rather than being eaten.
    up(service)
    down(service)
    #expect(spy.presses == ["start", "lock", "start"])

    // That fresh start parked a second checked continuation; resolve it.
    await driver.resolve(call: 2, .noRecording)
  }

  @Test("a missing publication path is reported as a fault, not as not-lockable")
  func unavailablePublicationIsDistinct() async {
    let spy = Spy()
    let clock = ManualClock()
    let driver = StartDriver()
    let service = makeService(spy, driver: driver, clock: clock)
    service.onStartRecording = driver.handler
    service.onLockRequested = nil  // nil collaborator: the fault case

    down(service)
    up(service)
    down(service)
    await driver.resolve(.recording("S1"))

    #expect(service.isRecordingLocked == false)
    #expect(spy.lockDecisions.count == 1)
    #expect(spy.lockDecisions.first?.committed == false)
    #expect(
      spy.lockDecisions.first?.reason == "publication_unavailable",
      "a nil collaborator must not be laundered as a pipeline verdict")
  }

  // MARK: - Staleness and preemption

  @Test("a superseded press's late result cannot touch the newer attempt")
  func supersededResultIsIgnored() async {
    let spy = Spy()
    let clock = ManualClock()
    let driver = StartDriver()
    let service = makeService(spy, driver: driver, clock: clock)
    var published = 0
    service.onStartRecording = driver.handler
    service.onLockRequested = { _ in
      published += 1
      return .published
    }

    down(service)  // press A, start parks
    up(service)
    service.handleCarbonHotkey(id: cancelID, isRelease: false)  // Escape: cleans A
    down(service)  // press B: a NEW attempt, overwriting the task slot
    up(service)
    await driver.resolve(call: 1, .noRecording)  // A's late result, after B replaced it

    // A's result must not have touched B's attempt.
    #expect(published == 0)

    // POSITIVE CONTROL: B still works. Without this the test would also pass for
    // a service that had broken every attempt, not just ignored the stale one.
    await driver.resolve(call: 2, .recording("S-B"))
    down(service)  // B's second press, inside its own window

    #expect(published == 1, "B must still be able to publish after A was ignored")
    #expect(service.isRecordingLocked)
  }

  @Test("a result arriving after stop() changes nothing")
  func resultAfterStopIsInert() async {
    let spy = Spy()
    let clock = ManualClock()
    let driver = StartDriver()
    let service = makeService(spy, driver: driver, clock: clock)
    var published = 0
    service.onStartRecording = driver.handler
    service.onLockRequested = { _ in
      published += 1
      return .published
    }

    down(service)
    service.stop()
    await driver.resolve(.noRecording)

    #expect(published == 0)
    #expect(service.isRecordingLocked == false)
    #expect(spy.lockDecisions.isEmpty)
  }

  @Test("a resolution while the key is still held leaves the later key-up harmless")
  func heldKeyAtResolution() async {
    let spy = Spy()
    let clock = ManualClock()
    let driver = StartDriver()
    let service = makeService(spy, driver: driver, clock: clock)
    var stops = 0
    service.onStartRecording = driver.handler
    service.onStopRecording = { stops += 1 }

    down(service)  // held, not released
    await driver.resolve(.noRecording)
    up(service)  // the physical release arrives after cleanup

    #expect(stops == 0, "there is nothing to stop")
    #expect(service.isModifierHeld == false)
  }

  @Test("an unwired start callback resolves as no-recording")
  func unwiredStartCallbackDoesNotLock() async {
    let spy = Spy()
    let clock = ManualClock()
    let service = makeService(spy, clock: clock)
    var published = 0
    service.onLockRequested = { _ in
      published += 1
      return .published
    }
    // onStartRecording deliberately left nil.

    down(service)
    up(service)
    await service.awaitInFlightStartForTesting()
    down(service)

    #expect(published == 0)
    #expect(spy.presses == ["start", "start"], "no callback means nothing recorded")
  }

  @Test("the accepted session id is carried unchanged to the publication query")
  func acceptedSessionIDIsCarried() async {
    let spy = Spy()
    let clock = ManualClock()
    let driver = StartDriver()
    let service = makeService(spy, driver: driver, clock: clock)
    var askedAbout: [String] = []
    service.onStartRecording = driver.handler
    service.onLockRequested = { sessionID in
      askedAbout.append(sessionID)
      return .published
    }

    down(service)
    up(service)
    down(service)
    await driver.resolve(.recording("A5A0C0DE-1631"))

    #expect(askedAbout == ["A5A0C0DE-1631"], "the id must not be recomputed at publication")
  }
}
