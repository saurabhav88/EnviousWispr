import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing
import os

/// #3544: the keyboard listener, the only reader of bare-modifier shortcuts from P3.
///
/// Product Outcome: when this fails, the listener is left running after the user stops or
/// suspends shortcuts (a tap holding their keys), two listeners run at once, a missing
/// Accessibility grant floods telemetry or never recovers, a held record key is never stopped after
/// a missed key-up, or a valid double tap is lost while the main thread is busy.
@MainActor
@Suite(.tags(.productOutcome), .timeLimit(.minutes(1)))
struct KeyboardListenerIntegrationTests {

  @MainActor private final class Rig {
    let clock = HotkeyTestClock(500)
    let timers: HotkeyTestScheduler
    let effects = RecordingDesktopHotkeyEffects()
    let service: HotkeyService
    var failures: [(mechanism: String, kind: String, shape: String)] = []
    var presses = 0
    var actions = 0

    init() {
      timers = HotkeyTestScheduler(clock: clock)
      final class Box { weak var rig: Rig? }
      let box = Box()
      service = HotkeyService(
        effects: effects,
        telemetry: HotkeyTelemetrySink(
          registrationFailed: { mechanism, kind, _, shape in
            box.rig?.failures.append((mechanism, kind, shape))
          },
          pressed: { _, _, _, _, _, _ in box.rig?.presses += 1 }),
        uptime: clock.uptime, scheduler: timers.scheduler)
      box.rig = self
      service.onToggleRecording = { [weak self] in self?.actions += 1 }
      service.onStartRecording = { [weak self] in
        self?.actions += 1
        return .noRecording
      }
    }

    var listenerFailures: Int { failures.filter { $0.mechanism == "event_tap" }.count }
  }

  @Test("start installs one listener and stop removes it")
  func startAndStop() throws {
    let rig = Rig()
    rig.service.start()
    #expect(rig.effects.keyboardListenerInstalls == 1)
    let token = try #require(rig.effects.keyboardListenerToken)
    rig.service.stop()
    #expect(rig.effects.removed.contains(token))
    #expect(rig.effects.keyboardListenerToken == nil)
    #expect(rig.listenerFailures == 0)
  }

  @Test("suspend removes the listener and resume installs a fresh one")
  func suspendAndResume() throws {
    let rig = Rig()
    rig.service.start()
    let first = try #require(rig.effects.keyboardListenerToken)
    let generation = rig.service.listenerGeneration
    rig.service.suspend()
    #expect(rig.effects.removed.contains(first))
    #expect(rig.effects.keyboardListenerToken == nil)
    rig.service.resume()
    #expect(rig.effects.keyboardListenerInstalls == 2)
    let second = try #require(rig.effects.keyboardListenerToken)
    #expect(second != first)
    #expect(rig.service.listenerGeneration > generation)
    rig.service.stop()
  }

  @Test("a shortcut restart replaces the listener exactly once")
  func restartReplacesOnce() {
    let rig = Rig()
    rig.service.start()
    rig.service.restartPreservingCancelArming()
    #expect(rig.effects.keyboardListenerInstalls == 2)
    #expect(rig.effects.keyboardListenerToken != nil)
    rig.service.stop()
  }

  @Test("a failed install is reported once and retried until it succeeds")
  func failedInstallReportsOnceAndRetries() async {
    let rig = Rig()
    let waiter = HotkeyGlobeKeyTests.CallbackWaiter()
    rig.service.onListenerRetryResolvedForTesting = { waiter.note() }
    rig.effects.failKeyboardListenerInstall = true
    rig.service.start()
    #expect(rig.listenerFailures == 1)
    #expect(rig.failures.first?.kind == ShortcutRole.record.telemetryKind)
    #expect(rig.failures.first?.shape == "modifier_only")
    #expect(rig.timers.requestedDelays == [TimingConstants.accessibilityPollIntervalSec])

    // Still failing: retried, not reported again.
    rig.clock.now += TimingConstants.accessibilityPollIntervalSec
    rig.timers.fireDue()
    await waiter.wait(until: 1)
    #expect(rig.effects.keyboardListenerInstalls == 2)
    #expect(rig.listenerFailures == 1)

    // Accessibility granted: the next retry installs and stops retrying.
    rig.effects.failKeyboardListenerInstall = false
    rig.clock.now += TimingConstants.accessibilityPollIntervalSec
    rig.timers.fireDue()
    await waiter.wait(until: 2)
    #expect(rig.effects.keyboardListenerInstalls == 3)
    #expect(rig.effects.keyboardListenerToken != nil)
    #expect(rig.timers.pendingCount == 0)
    #expect(rig.listenerFailures == 1)
    rig.service.stop()
  }

  @Test("a retry scheduled before stop never installs a listener after it")
  func staleRetryInstallsNothing() async {
    let rig = Rig()
    let waiter = HotkeyGlobeKeyTests.CallbackWaiter()
    rig.service.onListenerRetryResolvedForTesting = { waiter.note() }
    rig.effects.failKeyboardListenerInstall = true
    // A cancelled timer that fires anyway, as a handler already running would.
    let fires = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])
    let service = HotkeyService(
      effects: rig.effects, telemetry: .noop, uptime: rig.clock.uptime,
      scheduler: { _, fire in
        fires.withLock { $0.append(fire) }
        return RecordGestureEngine.TimerHandle(cancel: {})
      })
    service.onListenerRetryResolvedForTesting = { waiter.note() }
    service.start()
    service.stop()
    rig.effects.failKeyboardListenerInstall = false
    let installs = rig.effects.keyboardListenerInstalls
    fires.withLock { $0 }.first?()
    await waiter.wait(until: 1)
    #expect(rig.effects.keyboardListenerInstalls == installs)
    #expect(rig.effects.keyboardListenerToken == nil)
  }

  @Test("a refused removal keeps the old listener and no second one is installed")
  func refusedRemovalBlocksASecondListener() throws {
    let rig = Rig()
    rig.service.start()
    let token = try #require(rig.effects.keyboardListenerToken)
    rig.effects.refuseRemovals = true
    rig.service.suspend()
    rig.service.resume()
    #expect(rig.effects.keyboardListenerInstalls == 1)
    #expect(rig.effects.keyboardListenerToken == token)
    rig.effects.refuseRemovals = false
    rig.service.stop()
  }

  @Test("the listener passes every event through, its own shortcut presses included")
  func listenerPassesEverythingThrough() throws {
    let rig = Rig()
    rig.service.recordingMode = .pushToTalk
    rig.service.start()
    let sink = try #require(rig.effects.keyboardListenerSink)
    for (flags, t) in [(UInt64(0x80040), 0.0), (0, 0.1), (0x80040, 0.2), (0, 0.3)] {
      let verdict = sink(
        KeyEventValue(kind: .flagsChanged, keyCode: 61, rawFlags: flags, timestamp: 500 + t))
      #expect(verdict == .passThrough)
    }
    rig.service.stop()
  }

  @Test("Carbon still serves chords beside the listener")
  func carbonServesChords() {
    let rig = Rig()
    rig.service.start()
    #expect(rig.effects.carbonHandlerInstalls == 1)
    #expect(rig.effects.keyboardListenerInstalls == 1)
    rig.service.stop()
  }

  @Test("a stopped or suspended service installs no listener")
  func noListenerWhileStoppedOrSuspended() {
    let rig = Rig()
    rig.service.resume()  // not started: nothing
    #expect(rig.effects.keyboardListenerInstalls == 0)
    rig.service.start()
    rig.service.suspend()
    rig.service.reapplyCancelBinding()  // refused while suspended
    #expect(rig.effects.keyboardListenerInstalls == 1)
    #expect(rig.effects.keyboardListenerToken == nil)
    rig.service.stop()
  }

  @Test("a pending install retry does not keep a released service alive")
  func pendingRetryDoesNotRetainTheService() {
    let effects = RecordingDesktopHotkeyEffects()
    effects.failKeyboardListenerInstall = true
    let fires = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])
    weak var weakService: HotkeyService?
    do {
      let service = HotkeyService(
        effects: effects, telemetry: .noop, uptime: { 500 },
        scheduler: { _, fire in
          fires.withLock { $0.append(fire) }
          return RecordGestureEngine.TimerHandle(cancel: {})
        })
      weakService = service
      service.start()
      #expect(fires.withLock { $0.count } == 1)
    }
    #expect(weakService == nil)
  }

  @Test("a failed install of a chord record key reports the chord shape")
  func failedChordInstallReportsChord() {
    let rig = Rig()
    rig.service.toggleKeyCode = ModifierKeyCodes.rightOption
    rig.service.toggleModifiers = [.command]
    rig.effects.failKeyboardListenerInstall = true
    rig.service.start()
    #expect(rig.listenerFailures == 1)
    #expect(rig.failures.last?.mechanism == "event_tap")
    #expect(rig.failures.last?.kind == ShortcutRole.record.telemetryKind)
    #expect(rig.failures.last?.shape == "chord")
    rig.service.stop()
  }

  // MARK: - The listener as the record key's path (#3544 P3)

  /// A push-to-talk service on bare Right Option, started, with its keyboard.
  @MainActor private final class PTT {
    let clock = HotkeyTestClock(500)
    let timers: HotkeyTestScheduler
    let effects = RecordingDesktopHotkeyEffects()
    let service: HotkeyService
    let keys: ListenerKeyboard
    var starts = 0
    var joins = 0
    /// What a join finds: the running session's id, or nil once that session has ended.
    var joinable: String? = "menu"
    var stops = 0
    var published = 0
    init() {
      timers = HotkeyTestScheduler(clock: clock)
      service = HotkeyService(effects: effects, uptime: clock.uptime, scheduler: timers.scheduler)
      keys = ListenerKeyboard(effects)
      service.recordingMode = .pushToTalk
      service.toggleKeyCode = ModifierKeyCodes.rightOption
      service.toggleModifiers = []
      service.onStartRecording = { [unowned self] in
        starts += 1
        return .recording("s\(starts)")
      }
      service.onJoinRecording = { [unowned self] in
        joins += 1
        return joinable.map { .recording($0) } ?? .noRecording
      }
      service.onStopRecording = { [unowned self] in stops += 1 }
      service.onLockRequested = { [unowned self] _ in
        published += 1
        return .published
      }
      service.start()
    }
    func at(_ t: TimeInterval) { clock.now = 500 + t }
  }

  @Test("a held record key starts and its release stops, through the listener")
  func holdStartsAndReleaseStops() async {
    let ptt = PTT()
    defer { ptt.service.stop() }
    ptt.at(0)
    await ptt.keys.press(ModifierKeyCodes.rightOption, at: 500)
    await ptt.service.awaitInFlightStartForTesting()
    #expect(ptt.starts == 1)
    #expect(ptt.service.isModifierHeld)
    ptt.at(1.5)
    await ptt.keys.release(ModifierKeyCodes.rightOption, at: 501.5)
    await ptt.service.awaitInFlightStartForTesting()
    #expect(ptt.stops == 1)
    #expect(ptt.service.isModifierHeld == false)
  }

  /// The race #3534 is about: the second press arrives while main is still busy. The listener
  /// decides on its own thread, so the lock is decided before the lone-tap deadline even though
  /// main has not run anything since the first release.
  @Test("a double tap is decided while main is withheld, before the lone-tap deadline")
  func doubleTapDecidedOffMain() async throws {
    let ptt = PTT()
    defer { ptt.service.stop() }
    ptt.at(0)
    await ptt.keys.press(ModifierKeyCodes.rightOption, at: 500)
    await ptt.service.awaitInFlightStartForTesting()
    // Main withheld from here: main blocks on a worker that delivers the quick release and the
    // second press straight into the sink, so nothing queued to main can run before the checks.
    let sink = try #require(ptt.effects.keyboardListenerSink)
    let option = ListenerKeyboard.rawFlags([ModifierKeyCodes.rightOption])
    let clock = ptt.clock
    Self.onWorkerWhileMainWaits {
      clock.now = 500.125
      _ = sink(KeyEventValue(kind: .flagsChanged, keyCode: 61, rawFlags: 0, timestamp: 500.125))
      clock.now = 500.25
      _ = sink(
        KeyEventValue(kind: .flagsChanged, keyCode: 61, rawFlags: option, timestamp: 500.25))
    }
    #expect(ptt.service.isRecordingLocked, "locked by the engine before main ran")
    #expect(ptt.published == 0, "main has not run yet")
    // The lone-tap wait was cancelled by the second press: nothing fires at the deadline.
    ptt.at(0.625)
    ptt.timers.fireDue()
    await ListenerKeyboard.mainTurn()
    #expect(ptt.published == 1)
    #expect(ptt.stops == 0)
  }

  /// Run `work` on a worker while main blocks on that worker's own completion (bounded), so main
  /// runs nothing in between.
  private static func onWorkerWhileMainWaits(_ work: @escaping @Sendable () -> Void) {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInteractive).async {
      work()
      done.signal()
    }
    // deadline-fallback: bound the worker's own completion signal so a regression fails, not hangs.
    #expect(done.wait(timeout: .now() + 5) == .success)
  }

  @Test("a key released while suspended does not swallow the next press")
  func releaseWhileSuspendedDoesNotSwallow() async {
    let ptt = PTT()
    defer { ptt.service.stop() }
    ptt.at(0)
    await ptt.keys.press(ModifierKeyCodes.rightOption, at: 500)
    await ptt.service.awaitInFlightStartForTesting()
    ptt.service.suspend()  // the shortcut recorder opens; the key comes up unseen
    ptt.service.resume()
    ptt.at(5)
    // A fresh installation and a fresh hold: the next press starts a new dictation.
    await ptt.keys.release(ModifierKeyCodes.rightOption)  // keyboard model only; unheld release
    await ptt.keys.press(ModifierKeyCodes.rightOption, at: 505)
    await ptt.service.awaitInFlightStartForTesting()
    #expect(ptt.starts == 2)
  }

  /// The edge is queued to main while its installation is live; the rebind runs before main
  /// delivers it. Removing the listener cannot recall what it already queued (#1993).
  @Test("a toggle press queued before a rebind is refused when main delivers it")
  func staleMainEdgeIsRefused() async throws {
    let ptt = PTT()
    var toggles = 0
    ptt.service.onToggleRecording = { toggles += 1 }
    ptt.service.recordingMode = .toggle
    var judged: [Bool] = []
    let handled = HotkeyGlobeKeyTests.CallbackWaiter()
    ptt.service.onListenerEdgeHandledForTesting = { _, current in
      judged.append(current)
      handled.note()
    }
    let sink = try #require(ptt.effects.keyboardListenerSink)
    let option = ListenerKeyboard.rawFlags([ModifierKeyCodes.rightOption])
    // Live installation: the press is classified and its edge queued to main.
    Self.onWorkerWhileMainWaits {
      _ = sink(KeyEventValue(kind: .flagsChanged, keyCode: 61, rawFlags: option, timestamp: nil))
    }
    // The settings sync's re-registration, before main delivers the edge: enabled again at once.
    ptt.service.stop()
    ptt.service.start()
    defer { ptt.service.stop() }
    await handled.wait(until: 1)
    #expect(judged == [false], "an edge from the replaced installation was judged current")
    #expect(toggles == 0)
  }

  /// A live tap can deliver a press before `installKeyboardListener` returns; the engine must
  /// already admit that installation, or the hold records nothing and its release is unowned.
  @Test("a press delivered while the listener is still being installed is recorded")
  func pressDuringInstallIsRecorded() async {
    let ptt = PTT()
    defer { ptt.service.stop() }
    ptt.service.suspend()
    let option = ListenerKeyboard.rawFlags([ModifierKeyCodes.rightOption])
    let clock = ptt.clock
    ptt.effects.beforeKeyboardListenerInstallReturns = { sink in
      Self.onWorkerWhileMainWaits {
        clock.now = 500
        _ = sink(KeyEventValue(kind: .flagsChanged, keyCode: 61, rawFlags: option, timestamp: 500))
      }
    }
    ptt.service.resume()
    ptt.effects.beforeKeyboardListenerInstallReturns = nil
    await ListenerKeyboard.mainTurn()
    await ptt.service.awaitInFlightStartForTesting()
    #expect(ptt.starts == 1)
    ptt.at(1.5)
    await ptt.keys.deliver(ModifierKeyCodes.rightOption, raw: 0, at: 501.5)
    await ptt.service.awaitInFlightStartForTesting()
    #expect(ptt.stops == 1)
    #expect(ptt.service.isModifierHeld == false)
  }

  /// Toggle mode, bare Right Command as cancel: cancel, then the record key at once (listener) or
  /// the record chord (Carbon). The toggle must wait until the cancel has finished, or it finds the
  /// cancelled session still active and stops or ignores it instead of starting a new one.
  @Test(
    "a toggle press after a listener cancel waits for the cancel to finish",
    arguments: [false, true])
  func toggleWaitsForTheCancel(viaCarbon: Bool) async throws {
    let ptt = PTT()
    defer { ptt.service.stop() }
    ptt.service.recordingMode = .toggle
    ptt.service.cancelKeyCode = ModifierKeyCodes.rightCommand
    ptt.service.cancelModifiers = []
    var toggles = 0
    var cancels = 0
    var cancelGate: CheckedContinuation<Void, Never>?
    let cancelled = HotkeyGlobeKeyTests.CallbackWaiter()
    let reachedWait = HotkeyGlobeKeyTests.CallbackWaiter()
    let toggled = HotkeyGlobeKeyTests.CallbackWaiter()
    ptt.service.onToggleRecording = {
      toggles += 1
      toggled.note()
    }
    ptt.service.onCancelRecording = {
      cancels += 1
      cancelled.note()
      await withCheckedContinuation { cancelGate = $0 }
    }
    ptt.service.onListenerCancellationWaitForTesting = { reachedWait.note() }
    ptt.service.setCancelHotkeyEnabled(true)
    await ptt.keys.press(ModifierKeyCodes.rightCommand)
    await cancelled.wait(until: 1)
    #expect(cancels == 1)
    if viaCarbon {
      ptt.service.handleCarbonHotkey(id: 1, isRelease: false)
    } else {
      await ptt.keys.press(ModifierKeyCodes.rightOption)
    }
    await reachedWait.wait(until: 1)
    #expect(toggles == 0, "the toggle ran while the cancel was still tearing down")
    try #require(cancelGate).resume()
    cancelGate = nil
    await toggled.wait(until: 1)
    #expect(toggles == 1)
  }

  // MARK: - Other-key dismissal on main (#3544 P4, D2)

  private func letterDown(_ ptt: PTT, at t: TimeInterval) async {
    let sink = ptt.effects.keyboardListenerSink
    let event = KeyEventValue(kind: .keyDown, keyCode: 0, rawFlags: 0, timestamp: 500 + t)
    await Task.detached { _ = sink?(event) }.value
    await ListenerKeyboard.mainTurn()
  }

  @Test("an early other key dismisses exactly the session its press started, once, and stops nothing")
  func dismissalEndsTheStartedSession() async {
    let ptt = PTT()
    defer { ptt.service.stop() }
    var dismissed: [String] = []
    let done = HotkeyGlobeKeyTests.CallbackWaiter()
    ptt.service.onDismissRecording = { sessionID in
      dismissed.append(sessionID)
      done.note()
    }
    ptt.at(0)
    await ptt.keys.press(ModifierKeyCodes.rightOption, at: 500)
    await ptt.service.awaitInFlightStartForTesting()
    ptt.at(0.3)
    await letterDown(ptt, at: 0.3)
    await done.wait(until: 1)
    ptt.at(1.5)
    await ptt.keys.release(ModifierKeyCodes.rightOption, at: 501.5)
    await ListenerKeyboard.mainTurn()
    #expect(dismissed == ["s1"])
    #expect(ptt.stops == 0, "the dismissed hold's release stopped a recording")
  }

  /// The session may be loading its model (cancel not armed yet), and the listener may have just
  /// been reinstalled by a resume: the running-session signal survives both.
  @Test(
    "an early other key during a recording started elsewhere ends nothing; the release still stops it",
    arguments: [false, true])
  func joinedRecordingSurvivesInterference(resumed: Bool) async {
    let ptt = PTT()
    defer { ptt.service.stop() }
    var dismissed: [String] = []
    ptt.service.onDismissRecording = { dismissed.append($0) }
    ptt.service.setRecordingActive(true)  // a recording from the menu is running, cancel unarmed
    if resumed {
      ptt.service.suspend()
      ptt.service.resume()
      await ListenerKeyboard.mainTurn()
    }
    ptt.at(0)
    await ptt.keys.press(ModifierKeyCodes.rightOption, at: 500)
    await ptt.service.awaitInFlightStartForTesting()
    ptt.at(0.3)
    await letterDown(ptt, at: 0.3)
    ptt.at(1.5)
    await ptt.keys.release(ModifierKeyCodes.rightOption, at: 501.5)
    await ListenerKeyboard.mainTurn()
    #expect(dismissed.isEmpty, "interference ended a recording the press did not start")
    #expect(ptt.stops == 1, "the joined press lost its stop")
    #expect(ptt.joins == 1 && ptt.starts == 0, "a joining press asked to create a session")
  }

  /// The session a press found may end before main runs that press: the press only ever joins,
  /// so it creates nothing (a new take would start with an ordinary key held and no protection).
  @Test("a joining press whose session ended before it ran starts nothing")
  func expiredJoinStartsNothing() async {
    let ptt = PTT()
    defer { ptt.service.stop() }
    ptt.service.setRecordingActive(true)
    ptt.joinable = nil  // the menu take concluded before main ran the press
    ptt.at(0)
    await ptt.keys.press(ModifierKeyCodes.rightOption, at: 500)
    await ptt.service.awaitInFlightStartForTesting()
    ptt.at(1)
    await ptt.keys.release(ModifierKeyCodes.rightOption, at: 501)
    await ListenerKeyboard.mainTurn()
    #expect(ptt.joins == 1)
    #expect(ptt.starts == 0, "an expired join created a new session")
    #expect(ptt.stops == 0, "a refused join's release stopped something")
  }

  @Test("a dismissal during a pending start waits for that start and ends its session")
  func dismissalDuringPendingStart() async throws {
    let ptt = PTT()
    defer { ptt.service.stop() }
    var gate: CheckedContinuation<Void, Never>?
    let startEntered = HotkeyGlobeKeyTests.CallbackWaiter()
    ptt.service.onStartRecording = {
      startEntered.note()
      await withCheckedContinuation { gate = $0 }
      return .recording("slow")
    }
    var dismissed: [String] = []
    let done = HotkeyGlobeKeyTests.CallbackWaiter()
    ptt.service.onDismissRecording = { sessionID in
      dismissed.append(sessionID)
      done.note()
    }
    ptt.at(0)
    await ptt.keys.press(ModifierKeyCodes.rightOption, at: 500)
    await startEntered.wait(until: 1)
    ptt.at(0.2)
    await letterDown(ptt, at: 0.2)
    #expect(dismissed.isEmpty, "dismissed before its start produced a session")
    try #require(gate).resume()
    await done.wait(until: 1)
    #expect(dismissed == ["slow"])
  }

  @Test("a dismissed press whose start produced no recording dismisses nothing")
  func dismissalOfARefusedStartDoesNothing() async {
    let ptt = PTT()
    defer { ptt.service.stop() }
    ptt.service.onStartRecording = { .noRecording }
    var dismissed: [String] = []
    ptt.service.onDismissRecording = { dismissed.append($0) }
    ptt.at(0)
    await ptt.keys.press(ModifierKeyCodes.rightOption, at: 500)
    await ptt.service.awaitInFlightStartForTesting()
    ptt.at(0.2)
    await letterDown(ptt, at: 0.2)
    await ListenerKeyboard.mainTurn()
    #expect(dismissed.isEmpty, "a refused attempt's dismissal reached the app")
  }

  @Test("our own marked events and key code 179 change nothing")
  func markedAndIgnoredEventsDoNothing() async {
    let ptt = PTT()
    defer { ptt.service.stop() }
    await ptt.keys.deliver(
      ModifierKeyCodes.rightOption, raw: ListenerKeyboard.rawFlags([ModifierKeyCodes.rightOption]),
      isOurs: true)
    await ptt.keys.deliver(179, raw: UInt64(NSEvent.ModifierFlags.function.rawValue))
    await ptt.service.awaitInFlightStartForTesting()
    #expect(ptt.starts == 0)
    #expect(ptt.service.isModifierHeld == false)
  }

  @Test("a stop's teardown health is read after removal")
  func stopReadsHealthAfterRemoval() {
    let rig = Rig()
    rig.service.start()
    let before = rig.effects.keyboardListenerHealthQueries
    rig.service.stop()
    #expect(rig.effects.keyboardListenerHealthQueries > before)
    #expect(rig.effects.keyboardListenerToken == nil)
  }

  #if DEBUG
    @Test("the listener health line names its subject, unit and completeness")
    func healthLineFormat() {
      let line = HotkeyService.listenerHealthLine(
        reason: "stop",
        KeyboardListenerHealth(
          terminal: .removed, disableEpisodes: 1, reenables: 1,
          cost: KeyboardListenerCost(
            samples: 3, maxNanoseconds: 900, p99LowerNanoseconds: 724,
            p99UpperNanoseconds: 862, recordingNanoseconds: 20)),
        complete: true)
      #expect(
        line
          == "[listener] health reason=stop terminal=removed disable_episodes=1 reenables=1 "
          + "cost_subject=callback_entry_to_return_excluding_recording cost_unit=ns samples=3 "
          + "max=900 p99_bucket=[724,862) recording_uncontended_mean=20 complete=true")
    }
  #endif
}
