import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

/// #3534 — a fast double tap of the record key locks hands-free even when the Mac
/// is busy.
///
/// When this fails, a fast double tap on a busy Mac does not lock hands-free, a
/// fast tap is treated as a hold, or a lone tap stops at the wrong time.
///
/// Every key event is driven with the two times the bug is about: when the OS
/// says it HAPPENED (`timestamp`) and when the service HANDLED it (the injected
/// `uptime` at the call). The eight replays are the misses captured on
/// 2026-10-08 with the diagnostic build (plan §1); before #3534 each one took the
/// stop path because its release or second press was handled more than 500 ms
/// after the first press.
///
/// The lone-tap stop waits through the injected `sleep`, which parks until the
/// test calls `fireDueTimers()`, so "the second press is handled before the due
/// timer" and "the timer runs first" are both driven deterministically. The test
/// learns the timer finished from the service's own
/// `onDebounceResolvedForTesting`, and that a start reconciled from
/// `onStartResolvedForTesting`; no wall-clock waits.
@MainActor
// A broken wait fails in a minute instead of hanging the run.
@Suite(.tags(.productOutcome), .timeLimit(.minutes(1)))
struct HotkeyEventTimeDoubleTapTests {

  /// `HotkeyID.toggle` is private to `HotkeyService`; mirrored here.
  private static let toggleID: UInt32 = 1

  /// One key event: when it happened (nil = no OS time) and when it was handled.
  struct Event {
    let isPress: Bool
    let occurred: TimeInterval?
    let handled: TimeInterval
    static func press(_ occurred: TimeInterval?, handled: TimeInterval? = nil) -> Event {
      Event(isPress: true, occurred: occurred, handled: handled ?? occurred ?? 0)
    }
    static func release(_ occurred: TimeInterval?, handled: TimeInterval? = nil) -> Event {
      Event(isPress: false, occurred: occurred, handled: handled ?? occurred ?? 0)
    }
  }

  /// The service's clock, waits and callbacks, all under test control.
  @MainActor final class Rig {
    var now: TimeInterval = 1000

    // Parked lone-tap waits: the uptime each one ends at.
    private var timers: [Int: (deadline: TimeInterval, wake: CheckedContinuation<Void, Never>)] =
      [:]
    private var nextTimerID = 0
    private(set) var requestedDeadlines: [TimeInterval] = []
    private(set) var requestedDelays: [TimeInterval] = []

    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var cancels = 0
    private(set) var published = 0
    var lockAnswer: HandsFreeLockRequestResult = .published
    var startAnswer: RecordingStartOutcome = .recording("event-time-session")
    private(set) var presses: [(action: String, windowTiming: String?)] = []
    private(set) var lockDecisions: [(committed: Bool, reason: String)] = []

    // Bounded waits: a missing signal records an issue after 5 s instead of hanging.
    private let sleepRequestWaiter = HotkeyGlobeKeyTests.CallbackWaiter()
    private let debounceWaiter = HotkeyGlobeKeyTests.CallbackWaiter()
    private let startWaiter = HotkeyGlobeKeyTests.CallbackWaiter()

    var sink: HotkeyTelemetrySink {
      HotkeyTelemetrySink(
        registrationFailed: { _, _, _, _ in },
        pressed: { [weak self] _, _, _, _, action, timing in
          self?.presses.append((action, timing))
        },
        lockResolved: { [weak self] committed, reason in
          self?.lockDecisions.append((committed, reason))
        })
    }

    var actions: [String] { presses.map(\.action) }

    // test-fixture-timer: a fake wait; it parks until the test calls fireDueTimers(), never on a clock.
    func sleep(_ seconds: TimeInterval) async {
      let id = nextTimerID
      nextTimerID += 1
      let deadline = now + seconds
      requestedDeadlines.append(deadline)
      requestedDelays.append(seconds)
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          if Task.isCancelled {
            continuation.resume()
          } else {
            timers[id] = (deadline, continuation)
          }
          // After the timer is parked, so a test that fires next finds it.
          sleepRequestWaiter.note()
        }
      } onCancel: {
        Task { @MainActor in self.wake(id) }
      }
    }

    private func wake(_ id: Int) {
      timers.removeValue(forKey: id)?.wake.resume()
    }

    /// Wake every parked wait whose deadline has passed at `now`.
    func fireDueTimers() {
      for (id, timer) in timers where timer.deadline <= now + 1e-9 {
        timers.removeValue(forKey: id)
        timer.wake.resume()
      }
    }

    func noteDebounceResolved() { debounceWaiter.note() }
    func noteStartResolved() { startWaiter.note() }

    /// Park until the service has asked for `count` lone-tap waits. The stop
    /// task asks from inside its own Task, so the request lands after `drive`.
    func waitForSleepRequests(count: Int) async {
      await sleepRequestWaiter.wait(until: count)
    }

    /// Park until the service reports `count` finished lone-tap stop tasks.
    func waitForDebounce(count: Int) async {
      await debounceWaiter.wait(until: count)
    }

    /// Park until the service reports `count` reconciled starts.
    func waitForStarts(count: Int) async {
      await startWaiter.wait(until: count)
    }

    func wire(_ service: HotkeyService) {
      service.onStartRecording = { [weak self] in
        guard let self else { return .noRecording }
        self.starts += 1
        return self.startAnswer
      }
      service.onStopRecording = { [weak self] in self?.stops += 1 }
      service.onCancelRecording = { [weak self] in self?.cancels += 1 }
      service.onLockRequested = { [weak self] _ in
        guard let self else { return .unavailable }
        if case .published = self.lockAnswer { self.published += 1 }
        return self.lockAnswer
      }
      service.onStartResolvedForTesting = { [weak self] in self?.noteStartResolved() }
      service.onDebounceResolvedForTesting = { [weak self] in self?.noteDebounceResolved() }
    }
  }

  private func makeService(_ rig: Rig, keyCode: UInt16 = 0)
    -> (HotkeyService, RecordingDesktopHotkeyEffects)
  {
    let effects = RecordingDesktopHotkeyEffects()
    let service = HotkeyService(
      effects: effects, telemetry: rig.sink,
      // Strong: a stop task can outlive the test body; the rig holds no service.
      uptime: { rig.now },
      sleep: { await rig.sleep($0) })
    service.recordingMode = .pushToTalk
    // keyCode 0 ('A') is a chord, delivered through Carbon; Right Option is a bare modifier.
    service.toggleKeyCode = keyCode
    rig.wire(service)
    return (service, effects)
  }

  /// Deliver one event through the Carbon entry point at its handling time.
  private func drive(_ service: HotkeyService, _ rig: Rig, _ event: Event) {
    rig.now = event.handled
    service.handleCarbonHotkey(
      id: Self.toggleID, isRelease: !event.isPress, timestamp: event.occurred)
  }

  private func drive(_ service: HotkeyService, _ rig: Rig, _ events: [Event]) {
    for event in events { drive(service, rig, event) }
  }

  /// Let every queued recording task (start, stop or cancel) finish.
  private func settle(_ service: HotkeyService) async {
    await service.awaitInFlightStartForTesting()
  }

  // MARK: - The eight captured misses

  struct Replay: CustomTestStringConvertible, Sendable {
    let name: String
    let events: [(isPress: Bool, occurred: TimeInterval, handled: TimeInterval)]
    var testDescription: String { name }
  }

  /// Plan §1 and §11, in handling order. Times are seconds after a base of 1000.
  nonisolated static let replays: [Replay] = [
    Replay(
      name: "00:43:30 press 2 handled 284 ms late",
      events: [(true, 1000, 1000), (false, 1000.092, 1000.092), (true, 1000.244, 1000.528)]),
    Replay(
      name: "00:48:09 press 2 handled 429 ms late",
      events: [(true, 1000, 1000), (false, 1000.069, 1000.069), (true, 1000.168, 1000.596)]),
    Replay(
      name: "00:48:18 press 2 handled 191 ms late",
      events: [(true, 1000, 1000), (false, 1000.068, 1000.068), (true, 1000.345, 1000.534)]),
    Replay(
      name: "01:13:10 press 2 handled 613 ms late",
      events: [(true, 1000, 1000.125), (false, 1000.092, 1000.147), (true, 1000.187, 1000.800)]),
    Replay(
      name: "01:14:22 release handled 633 ms late",
      events: [(true, 1000, 1000), (false, 1000.056, 1000.689), (true, 1000.186, 1000.689)]),
    Replay(
      name: "01:14:57 press 2 handled 347 ms late",
      events: [(true, 1000, 1000.002), (false, 1000.054, 1000.124), (true, 1000.171, 1000.518)]),
    Replay(
      name: "01:15:25 release handled 695 ms late",
      events: [(true, 1000, 1000), (false, 1000.109, 1000.804), (true, 1000.450, 1000.804)]),
    Replay(
      name: "01:16:16 press 2 handled 82 ms late",
      events: [(true, 1000, 1000.001), (false, 1000.066, 1000.102), (true, 1000.465, 1000.547)]),
  ]

  @Test(
    "A captured fast double tap locks hands-free although its events were handled late",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/3534", "double tap missed under load"),
    arguments: replays)
  func capturedMissLocks(replay: Replay) async {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(
      service, rig,
      replay.events.map { Event(isPress: $0.isPress, occurred: $0.occurred, handled: $0.handled) })
    await rig.waitForStarts(count: 1)
    await settle(service)

    #expect(rig.actions == ["start", "lock"])
    #expect(rig.presses.last?.windowTiming == "rescued")
    #expect(service.isRecordingLocked)
    #expect(rig.published == 1, "the lock intent was recorded but never shown")
    #expect(rig.stops == 0, "the double tap stopped the recording")
  }

  // MARK: - The lone-tap stop deadline

  @Test("A lone quick tap stops 500 ms after its release happened, once")
  func loneTapStopsOnce() async throws {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000), .release(1000.08)])
    await rig.waitForSleepRequests(count: 1)

    let deadline = try #require(rig.requestedDeadlines.last)
    #expect(abs(deadline - 1000.58) < 1e-9)
    rig.now = 1000.58
    rig.fireDueTimers()
    await rig.waitForDebounce(count: 1)
    await settle(service)

    #expect(rig.stops == 1)
    #expect(rig.actions == ["start"])
  }

  @Test("A stop task that starts late still stops at the release deadline, not 500 ms after it ran")
  func lateStartingTimerKeepsTheDeadline() async throws {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000), .release(1000.08)])
    // The busy main thread runs the stop task 320 ms after the release was handled.
    rig.now = 1000.40
    await rig.waitForSleepRequests(count: 1)

    let delay = try #require(rig.requestedDelays.last)
    #expect(abs(delay - 0.18) < 1e-9)
    let deadline = try #require(rig.requestedDeadlines.last)
    #expect(abs(deadline - 1000.58) < 1e-9)
    rig.now = 1000.58
    rig.fireDueTimers()
    await rig.waitForDebounce(count: 1)
    await settle(service)
    #expect(rig.stops == 1)
  }

  @Test("A stop task that starts after its deadline waits no longer and stops once")
  func timerStartingAfterDeadlineStopsAtOnce() async throws {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000), .release(1000.08)])
    rig.now = 1000.70
    await rig.waitForSleepRequests(count: 1)

    let delay = try #require(rig.requestedDelays.last)
    #expect(delay == 0)
    rig.fireDueTimers()
    await rig.waitForDebounce(count: 1)
    await settle(service)
    #expect(rig.stops == 1)
    #expect(rig.actions == ["start"])
  }

  @Test(
    "A release handled late gets a deadline that is already due, and a press handled first still locks"
  )
  func overdueDeadlinePressFirstLocks() async throws {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000), .release(1000.056, handled: 1000.689)])
    await rig.waitForSleepRequests(count: 1)

    // The deadline is 500 ms after the release HAPPENED (1000.556), so it was
    // already due when the release was handled at 1000.689: no wait remains.
    let delay = try #require(rig.requestedDelays.last)
    #expect(delay == 0)

    drive(service, rig, .press(1000.186, handled: 1000.689))
    rig.fireDueTimers()
    await rig.waitForDebounce(count: 1)
    await rig.waitForStarts(count: 1)
    await settle(service)

    #expect(rig.actions == ["start", "lock"])
    #expect(rig.published == 1)
    #expect(rig.stops == 0)
  }

  @Test(
    "When the due timer runs before the second press is handled, it stops once and the press starts fresh"
  )
  func overdueDeadlineTimerFirstStopsOnce() async {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000), .release(1000.056, handled: 1000.689)])
    await rig.waitForSleepRequests(count: 1)
    rig.fireDueTimers()
    await rig.waitForDebounce(count: 1)
    await settle(service)
    #expect(rig.stops == 1)

    drive(service, rig, .press(1000.186, handled: 1000.700))
    await settle(service)

    #expect(rig.stops == 1, "the stop was requested twice")
    #expect(rig.actions == ["start", "start"])
    #expect(service.isRecordingLocked == false)
  }

  // MARK: - Gestures that must not change

  @Test("An ordinary fast double tap locks and is marked on time")
  func ordinaryLockIsOnTime() async {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000), .release(1000.08), .press(1000.15)])
    await settle(service)

    #expect(rig.actions == ["start", "lock"])
    #expect(rig.presses.last?.windowTiming == "on_time")
    #expect(rig.published == 1)
  }

  @Test("A second press exactly 500 ms after the first locks")
  func pressAtWindowEdgeLocks() async {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000), .release(1000.125), .press(1000.5)])
    await settle(service)
    #expect(rig.actions == ["start", "lock"])
  }

  @Test(
    "A second press 501 ms after the first is late: no lock, logged, and its release stops once")
  func latePressKeepsTodaysOutcome() async {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000), .release(1000.07), .press(1000.501)])
    #expect(rig.actions == ["start", "late_after_window"])
    #expect(rig.presses.last?.windowTiming == nil)
    #expect(service.isRecordingLocked == false)

    drive(service, rig, .release(1000.6))
    await rig.waitForDebounce(count: 1)
    await settle(service)
    #expect(rig.stops == 1)
  }

  @Test("A genuinely slow second press stays a miss, exactly as before")
  func genuinelyLatePress() async {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000), .release(1000.07), .press(1000.62), .release(1000.7)])
    await rig.waitForDebounce(count: 1)
    await settle(service)

    #expect(rig.actions == ["start", "late_after_window"])
    #expect(rig.published == 0)
    #expect(rig.stops == 1)
  }

  @Test("A held press stops on release, without waiting")
  func heldPressStopsImmediately() async {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000), .release(1000.9)])
    await settle(service)

    #expect(rig.stops == 1)
    #expect(rig.requestedDeadlines.isEmpty)
  }

  @Test("A triple tap cancels")
  func tripleTapCancels() async {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(
      service, rig,
      [.press(1000), .release(1000.1), .press(1000.2), .release(1000.3), .press(1000.4)])
    await settle(service)

    #expect(rig.actions == ["start", "lock", "cancel"])
    #expect(rig.cancels == 1)
  }

  @Test("A third press exactly 500 ms after the first still cancels, before the lock cooldown")
  func thirdPressAtWindowEdgeCancels() async {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(
      service, rig,
      [.press(1000), .release(1000.1), .press(1000.2), .release(1000.3), .press(1000.5)])
    await settle(service)
    #expect(rig.actions == ["start", "lock", "cancel"])
  }

  @Test("A finger bounce right after a rescued lock is ignored by the cooldown")
  func cooldownAfterRescuedLock() async {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(
      service, rig,
      [
        .press(1000), .release(1000.1), .press(1000.2, handled: 1000.7),
        .release(1000.25, handled: 1000.75), .press(1000.6, handled: 1000.8),
      ])
    await settle(service)

    #expect(rig.actions == ["start", "lock", "ignored_cooldown"])
    #expect(rig.presses.count == 3)
    #expect(rig.presses.dropFirst().first?.windowTiming == "rescued")
    #expect(rig.stops == 0)
    #expect(rig.cancels == 0)
  }

  // MARK: - Missing or implausible OS times fall back to handling time

  @Test("With no OS times at all, a late-handled second press is a miss, as before")
  func missingTimestampsBehaveAsBefore() async throws {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(
      service, rig,
      [
        Event(isPress: true, occurred: nil, handled: 1000),
        Event(isPress: false, occurred: nil, handled: 1000.092),
      ])
    // Read the wait before the next press moves the clock: the rig stamps it at `now`.
    await rig.waitForSleepRequests(count: 1)
    let deadline = try #require(rig.requestedDeadlines.last)
    #expect(abs(deadline - 1000.592) < 1e-9)

    drive(service, rig, Event(isPress: true, occurred: nil, handled: 1000.528))
    #expect(rig.actions == ["start", "late_after_window"])
  }

  @Test("A zero release time is ignored: the pair uses handling time and never goes negative")
  func zeroReleaseTimeUsesHandlingPair() async {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000), Event(isPress: false, occurred: 0, handled: 1000.6)])
    await settle(service)

    #expect(rig.stops == 1, "a 600 ms handled hold must stop at once")
    #expect(rig.requestedDeadlines.isEmpty)
  }

  @Test("A zero start time with a valid release uses handling time for the window and the deadline")
  func zeroStartTimeUsesHandlingPair() async throws {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(
      service, rig,
      [Event(isPress: true, occurred: 0, handled: 1000), .release(1000.3, handled: 1000.4)])
    await rig.waitForSleepRequests(count: 1)
    let deadline = try #require(rig.requestedDeadlines.last)
    #expect(abs(deadline - 1000.9) < 1e-9)
  }

  @Test("A release time earlier than the press time uses handling time for both")
  func reversedOccurrencePairUsesHandlingPair() async throws {
    let rig = Rig()
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000.2), .release(1000.1, handled: 1000.3)])
    await rig.waitForSleepRequests(count: 1)
    let deadline = try #require(rig.requestedDeadlines.last)
    #expect(abs(deadline - 1000.8) < 1e-9)
  }

  @Test("An OS time exactly 2 s old is used; 2.001 s old is not")
  func ageAcceptanceEdge() async throws {
    let accepted = Rig()
    let (service, _) = makeService(accepted)
    defer { service.stop() }
    drive(service, accepted, [.press(1000), .release(1000, handled: 1000 + 2.0)])
    await accepted.waitForSleepRequests(count: 1)
    // Accepted: the release happened at the press, so it is a quick tap whose
    // deadline (1000.5) has already passed.
    let delay = try #require(accepted.requestedDelays.last)
    #expect(delay == 0)
    #expect(accepted.stops == 0)

    let rejected = Rig()
    let (other, _) = makeService(rejected)
    defer { other.stop() }
    drive(other, rejected, [.press(1000), .release(1000, handled: 1000 + 2.001)])
    await settle(other)
    // Rejected: judged by handling time, a 2 s hold, so it stops at once.
    #expect(rejected.requestedDeadlines.isEmpty)
    #expect(rejected.stops == 1)
  }

  @Test("An OS time up to 50 ms in the future is used; 51 ms is not")
  func futureAcceptanceEdge() async throws {
    let handled: TimeInterval = 1000.1875
    let accepted = Rig()
    let (service, _) = makeService(accepted)
    defer { service.stop() }
    drive(service, accepted, [.press(1000), .release(handled + 0.05, handled: handled)])
    await accepted.waitForSleepRequests(count: 1)
    let acceptedDeadline = try #require(accepted.requestedDeadlines.last)
    #expect(abs(acceptedDeadline - (handled + 0.05 + 0.5)) < 1e-9)

    let rejected = Rig()
    let (other, _) = makeService(rejected)
    defer { other.stop() }
    drive(other, rejected, [.press(1000), .release(handled + 0.051, handled: handled)])
    await rejected.waitForSleepRequests(count: 1)
    let rejectedDeadline = try #require(rejected.requestedDeadlines.last)
    #expect(abs(rejectedDeadline - (handled + 0.5)) < 1e-9)
  }

  // MARK: - Every path that delivers a key carries its OS time

  @Test("A bare-modifier double tap handled late locks through the modifier path")
  func modifierPathReplayLocks() async {
    let rig = Rig()
    let (service, _) = makeService(rig, keyCode: ModifierKeyCodes.rightOption)
    defer { service.stop() }
    func flags(_ down: Bool, _ occurred: TimeInterval, _ handled: TimeInterval) {
      rig.now = handled
      service.handleFlagsChangedValues(
        keyCode: ModifierKeyCodes.rightOption, flags: down ? [.option] : [], timestamp: occurred)
    }
    flags(true, 1000, 1000)
    flags(false, 1000.092, 1000.092)
    flags(true, 1000.244, 1000.528)
    await settle(service)

    #expect(rig.actions == ["start", "lock"])
    #expect(rig.presses.last?.windowTiming == "rescued")
  }

  @Test("The installed global and local modifier monitors forward the OS time")
  func installedModifierMonitorsForwardTimestamp() async throws {
    for useGlobal in [true, false] {
      let rig = Rig()
      let (service, effects) = makeService(rig, keyCode: ModifierKeyCodes.rightOption)
      service.start()
      defer { service.stop() }
      let callback = try #require(
        useGlobal ? effects.globalMonitorCallback : effects.localMonitorCallback)
      let option = UInt64(NSEvent.ModifierFlags.option.rawValue)
      func send(_ raw: UInt64, _ occurred: TimeInterval, _ handled: TimeInterval) {
        rig.now = handled
        callback(
          DesktopModifierEvent(
            keyCode: ModifierKeyCodes.rightOption, rawFlags: raw, timestamp: occurred))
      }
      send(option, 1000, 1000)
      send(0, 1000.092, 1000.092)
      send(option, 1000.244, 1000.528)
      await settle(service)

      #expect(rig.actions == ["start", "lock"], "monitor: \(useGlobal ? "global" : "local")")
      #expect(rig.presses.last?.windowTiming == "rescued")
    }
  }

  @Test("The installed Carbon handler forwards the OS time")
  func installedCarbonHandlerForwardsTimestamp() async throws {
    let rig = Rig()
    let (service, effects) = makeService(rig)
    service.start()
    defer { service.stop() }
    let callback = try #require(effects.carbonCallback)
    func send(_ release: Bool, _ occurred: TimeInterval, _ handled: TimeInterval) {
      rig.now = handled
      callback(DesktopHotkeyEvent(id: Self.toggleID, isRelease: release, timestamp: occurred))
    }
    send(false, 1000, 1000)
    send(true, 1000.092, 1000.092)
    send(false, 1000.244, 1000.528)
    await settle(service)

    #expect(rig.actions == ["start", "lock"])
    #expect(rig.presses.last?.windowTiming == "rescued")
  }

  @Test("A timestamped event from a torn-down monitor is ignored")
  func staleInstalledCallbackIgnored() async throws {
    let rig = Rig()
    let (service, effects) = makeService(rig, keyCode: ModifierKeyCodes.rightOption)
    defer { service.stop() }
    service.start()
    let stale = try #require(effects.globalMonitorCallback)
    service.stop()
    service.start()
    defer { service.stop() }

    rig.now = 1000
    stale(
      DesktopModifierEvent(
        keyCode: ModifierKeyCodes.rightOption,
        rawFlags: UInt64(NSEvent.ModifierFlags.option.rawValue), timestamp: 1000))
    await settle(service)
    #expect(rig.starts == 0)
    #expect(rig.actions.isEmpty)
  }

  // MARK: - Start and publication decisions are unchanged

  @Test("A start the app refused, during the pending stop, leaves the next press a fresh start")
  func refusedStartThenPressStartsFresh() async {
    let rig = Rig()
    rig.startAnswer = .noRecording
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000), .release(1000.08)])
    await rig.waitForStarts(count: 1)
    await rig.waitForDebounce(count: 1)
    drive(service, rig, .press(1000.2, handled: 1000.6))
    await rig.waitForStarts(count: 2)

    #expect(rig.actions == ["start", "start"])
    #expect(rig.published == 0)
    #expect(rig.stops == 0)
  }

  @Test("A lock the app refused to show keeps the timing it was recorded with")
  func rejectedPublicationKeepsWindowTiming() async {
    let rig = Rig()
    rig.lockAnswer = .notLockable
    let (service, _) = makeService(rig)
    defer { service.stop() }
    drive(service, rig, [.press(1000), .release(1000.092)])
    await rig.waitForStarts(count: 1)  // accepted before the second press, so it publishes inline
    drive(service, rig, .press(1000.244, handled: 1000.528))
    await rig.waitForDebounce(count: 1)

    #expect(rig.actions == ["start", "lock"])
    #expect(rig.presses.last?.windowTiming == "rescued")
    #expect(rig.lockDecisions.map(\.reason) == ["not_lockable_at_publication"])
    #expect(service.isRecordingLocked == false)
  }
}
