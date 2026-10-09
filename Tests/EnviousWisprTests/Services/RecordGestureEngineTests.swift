import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing
import os

/// #3544 P1 — the record-key gesture engine decides under its lock and hands decisions to the
/// main thread in decision order.
///
/// When this fails, a busy Mac drops a hands-free double tap, a stale stop ends a newer
/// dictation, or a cancelled attempt's leftover decisions still act.
///
/// Background input is driven through `ingest` (the path a listener thread will use), whose
/// effects wait for a main-queue drain the test withholds and then releases with
/// `drainForTesting()`. Time and the lone-tap wait are the hand-driven test fixtures.
@MainActor
@Suite(.tags(.productOutcome), .timeLimit(.minutes(1)))
struct RecordGestureEngineTests {

  private typealias T = RecordGesture.InputTime

  /// Every batch the engine delivered, flattened to readable effect names, in order.
  @MainActor final class Sink {
    var delivered: [(name: String, valid: Bool, attempt: UInt64)] = []
    var onBatch: ((RecordGestureEngine.Batch) -> Void)?
    func record(_ batch: RecordGestureEngine.Batch, valid: Bool) {
      for effect in batch.effects {
        delivered.append((Self.name(effect), valid, batch.attemptID))
      }
      onBatch?(batch)
    }
    var validNames: [String] { delivered.filter(\.valid).map(\.name) }
    static func name(_ effect: RecordGestureEngine.Effect) -> String {
      switch effect {
      case .press(let press):
        switch press.decision {
        case .start: return "start"
        case .tripleCancel: return "tripleCancel"
        case .lockIntent: return "lockIntent"
        case .ignoredCooldown: return "ignoredCooldown"
        case .stopLocked: return "stopLocked"
        case .lateAfterWindow: return "lateAfterWindow"
        }
      case .holdStop: return "holdStop"
      case .quickRelease: return "quickRelease"
      case .loneTapStop: return "loneTapStop"
      case .loneTapResolved: return "resolved"
      case .cancel: return "cancel"
      case .dismiss: return "dismiss"
      }
    }
  }

  @MainActor private struct Rig {
    let clock = HotkeyTestClock(500)
    let timers: HotkeyTestScheduler
    let engine: RecordGestureEngine
    let sink = Sink()
    init() {
      timers = HotkeyTestScheduler(clock: clock)
      engine = RecordGestureEngine(
        binding: .keyboard(keyCode: ModifierKeyCodes.rightOption, modifiers: []),
        mode: .pushToTalk, clock: clock.uptime, scheduler: timers.scheduler)
      let sink = self.sink
      engine.setSink { @MainActor batch, valid in sink.record(batch, valid: valid) }
    }
    /// An input that happened and was handled at `t` (seconds after 500).
    func at(_ t: TimeInterval) -> T { T.accepting(stamp: 500 + t, handled: 500 + t) }
    /// Ingest from a real worker thread (the path a listener thread will use), then wait for
    /// that worker, never for the main thread: its effects stay queued until a drain.
    func background(_ isPress: Bool, _ t: TimeInterval) {
      let engine = self.engine
      let clock = self.clock
      let input = at(t)
      RecordGestureEngineTests.offMain {
        clock.now = 500 + t
        engine.ingest(isPress: isPress, input: input)
      }
    }
    /// Fire due lone-tap waits from a worker thread, as the timer queue does.
    func fireDueOffMain() {
      let timers = self.timers
      RecordGestureEngineTests.offMain { timers.fireDue() }
    }
    func main(_ isPress: Bool, _ t: TimeInterval) {
      clock.now = 500 + t
      engine.ingestOnMain(isPress: isPress, input: at(t))
    }
  }

  /// Run `work` on a worker thread and wait for THAT worker (bounded), asserting it ran off main.
  private static func offMain(_ work: @escaping @Sendable () -> Void) {
    let done = DispatchSemaphore(value: 0)
    let wasOffMain = OSAllocatedUnfairLock(initialState: false)
    DispatchQueue.global(qos: .userInteractive).async {
      wasOffMain.withLock { $0 = !Thread.isMainThread }
      work()
      done.signal()
    }
    // deadline-fallback: bound the worker's own completion signal so a regression fails, not hangs.
    #expect(done.wait(timeout: .now() + 5) == .success)
    #expect(wasOffMain.withLock { $0 })
  }

  @Test("a double tap decided off the main thread locks, even when the main thread is late")
  func backgroundDoubleTapLocksWhileMainIsWithheld() {
    let rig = Rig()
    rig.background(true, 0)  // first press
    rig.background(false, 0.125)  // quick release: the lone-tap stop is scheduled for 0.625
    rig.background(true, 0.25)  // second press, 250 ms after the first
    // The main thread was busy past the deadline; the engine already decided.
    rig.clock.now = 501
    rig.fireDueOffMain()
    #expect(rig.sink.delivered.isEmpty)  // nothing reached main yet
    rig.engine.drainForTesting()
    #expect(rig.sink.validNames == ["start", "quickRelease", "resolved", "lockIntent"])
    #expect(rig.engine.snapshot.isLocked)
  }

  @Test("a stop the timer queued is applied before a later main-thread press, never after")
  func queuedTimerStopPrecedesALaterMainPress() {
    let rig = Rig()
    rig.background(true, 0)
    rig.background(false, 0.125)
    rig.clock.now = 500.625
    rig.fireDueOffMain()  // the lone-tap stop is queued for main
    rig.main(true, 1.0)  // a new press on main drains everything, oldest first
    #expect(
      rig.sink.validNames == ["start", "quickRelease", "loneTapStop", "resolved", "start"])
    #expect(rig.sink.delivered.last?.attempt == 2)
  }

  @Test("two whole gestures queued behind a withheld main thread are applied in order")
  func twoQueuedGesturesKeepTheirOrder() {
    let rig = Rig()
    rig.background(true, 0)
    rig.background(false, 1.0)  // held 1 s: a hold stop
    rig.background(true, 2.0)
    rig.background(false, 3.0)
    rig.engine.drainForTesting()
    #expect(rig.sink.validNames == ["start", "holdStop", "start", "holdStop"])
    #expect(rig.sink.delivered.map(\.attempt) == [1, 1, 2, 2])
  }

  @Test("refusing an older attempt drops only its batches; the newer attempt is untouched")
  func refusalDropsOnlyThatAttempt() {
    let rig = Rig()
    rig.background(true, 0)
    rig.background(false, 1.0)  // attempt 1 ends with a hold stop
    rig.background(true, 2.0)  // attempt 2 starts
    rig.engine.reset(attempt: 1)  // drains on main: attempt 1 refused before execution
    #expect(rig.sink.delivered.map(\.valid) == [false, false, true])
    #expect(rig.sink.validNames == ["start"])
    #expect(rig.engine.snapshot.isHeld)  // attempt 2's held key survives
  }

  @Test("refusing the live attempt cancels its lone-tap wait, which reports it finished")
  func refusalCancelsThatAttemptsTimer() {
    let rig = Rig()
    rig.background(true, 0)
    rig.background(false, 0.125)
    #expect(rig.timers.pendingCount == 1)
    rig.engine.reset(attempt: 1)
    #expect(rig.timers.pendingCount == 0)
    rig.clock.now = 501
    rig.fireDueOffMain()
    rig.engine.drainForTesting()
    #expect(rig.sink.delivered.filter { $0.name == "loneTapStop" }.isEmpty)
    #expect(rig.sink.delivered.filter { $0.name == "resolved" }.count == 1)
  }

  @Test("an explicit reset drops every decision queued before it")
  func resetDropsQueuedDecisions() {
    let rig = Rig()
    rig.background(true, 0)
    rig.background(false, 1.0)
    rig.engine.reset()
    #expect(rig.sink.validNames.isEmpty)
    #expect(rig.sink.delivered.count == 2)
    rig.main(true, 2.0)
    #expect(rig.sink.validNames == ["start"])
  }

  @Test("a reset made while a batch is being applied drops the batches after it")
  func resetDuringDrainDropsLaterBatches() {
    let rig = Rig()
    rig.background(true, 0)
    rig.background(false, 1.0)
    var resetDone = false
    rig.sink.onBatch = { [weak engine = rig.engine] _ in
      if !resetDone {
        resetDone = true
        engine?.reset()
      }
    }
    rig.engine.drainForTesting()
    #expect(rig.sink.delivered.map(\.valid) == [true, false])
  }

  @Test("a late held-key clear is skipped when a later input already moved the key")
  func deferredHeldClearSkipsNewerInput() {
    let rig = Rig()
    // A held clear decided for the first input (sequence 1) must not undo the second press.
    rig.main(true, 0)
    rig.main(false, 1.0)
    rig.main(true, 2.0)
    rig.engine.forgetHeld(ifNoInputAfter: 1)
    #expect(rig.engine.snapshot.isHeld)
    rig.engine.forgetHeld(ifNoInputAfter: 3)
    #expect(rig.engine.snapshot.isHeld == false)
  }

  @Test("executing a late lone-tap stop never erases the newer dictation the next press started")
  func lateStopDoesNotEraseTheNextAttempt() async {
    let clock = HotkeyTestClock(500)
    let timers = HotkeyTestScheduler(clock: clock)
    let service = HotkeyService(
      effects: RecordingDesktopHotkeyEffects(), uptime: clock.uptime, scheduler: timers.scheduler)
    defer { service.stop() }
    service.recordingMode = .pushToTalk
    service.toggleKeyCode = 0  // a chord, delivered through Carbon
    final class Counts { var starts = 0; var stops = 0; var published = 0 }
    let counts = Counts()
    service.onStartRecording = {
      counts.starts += 1
      return .recording("session-\(counts.starts)")
    }
    service.onStopRecording = { counts.stops += 1 }
    service.onLockRequested = { _ in
      counts.published += 1
      return .published
    }
    func carbon(_ isPress: Bool, _ t: TimeInterval) {
      clock.now = 500 + t
      service.handleCarbonHotkey(id: 1, isRelease: !isPress, timestamp: 500 + t)
    }
    carbon(true, 0)
    await service.awaitInFlightStartForTesting()
    carbon(false, 0.125)
    let resolved = HotkeyGlobeKeyTests.CallbackWaiter()
    service.onDebounceResolvedForTesting = { resolved.note() }
    clock.now = 500.625
    // P1: the timer's decision is queued on main (H); it decides the stop and queues its delivery
    // (D). A key event main already holds (P) runs between them: attempt 2 is decided before the
    // stop is executed, so the stop is executed LATE, inside attempt 2's drain.
    timers.fireDue()  // enqueues H
    DispatchQueue.main.async { carbon(true, 1.0) }  // P, after H and before D
    await resolved.wait(until: 1)
    await service.awaitInFlightStartForTesting()
    #expect(counts.stops == 1)
    #expect(counts.starts == 2)
    #expect(service.isModifierHeld)
    // Attempt 2 is alive: a quick release and a second press lock it.
    carbon(false, 1.125)
    carbon(true, 1.25)
    #expect(counts.published == 1)
    #expect(service.isRecordingLocked)
  }

  @Test("an input made while a batch is being applied is applied by the same drain, after it")
  func reentrantAppendIsAppliedInOrderWithoutRecursion() {
    let rig = Rig()
    var depth = 0
    var maxDepth = 0
    var appended = false
    rig.sink.onBatch = { [weak engine = rig.engine, clock = rig.clock] _ in
      depth += 1
      maxDepth = max(maxDepth, depth)
      if !appended {
        appended = true
        clock.now = 501
        engine?.ingestOnMain(isPress: false, input: .accepting(stamp: 501, handled: 501))
      }
      depth -= 1
    }
    rig.main(true, 0)  // start; its application ingests a hold release
    #expect(rig.sink.validNames == ["start", "holdStop"])
    #expect(maxDepth == 1)
  }

  @Test("a worker's input made while main applies the last queued batch is still applied once")
  func backgroundAppendAtDrainCompletionIsApplied() {
    let rig = Rig()
    let engine = rig.engine
    let clock = rig.clock
    var appended = false
    rig.sink.onBatch = { [weak engine] _ in
      guard !appended, let engine else { return }
      appended = true
      // While main is inside the drain's last batch, a worker appends a release.
      RecordGestureEngineTests.offMain {
        clock.now = 501
        engine.ingest(isPress: false, input: .accepting(stamp: 501, handled: 501))
      }
    }
    rig.main(true, 0)
    #expect(rig.sink.validNames == ["start", "holdStop"])
  }

  @Test("a pending main-queue drain after a synchronous drain applies nothing twice")
  func pendingAsyncDrainAfterSyncDrainAppliesNothingTwice() async {
    let rig = Rig()
    let waiter = HotkeyGlobeKeyTests.CallbackWaiter()
    @MainActor final class Count { var value = 0 }
    let completions = Count()
    rig.engine.onAsyncDrainResolvedForTesting = {
      completions.value += 1
      waiter.note()
    }
    defer { rig.engine.onAsyncDrainResolvedForTesting = nil }

    rig.background(true, 0)  // claims a main-queue drain
    rig.main(false, 1.0)  // drains everything on this turn
    #expect(rig.sink.validNames == ["start", "holdStop"])

    // The pending main-queue drain runs and must apply nothing again.
    await waiter.wait(until: 1)
    #expect(completions.value == 1)
    #expect(rig.sink.validNames == ["start", "holdStop"])
  }

  /// A service on the hand-driven clock and timer, recording what it did.
  @MainActor final class ServiceRig {
    let clock = HotkeyTestClock(500)
    let timers: HotkeyTestScheduler
    let service: HotkeyService
    var actions: [String] = []
    var starts = 0
    var published = 0
    init() {
      timers = HotkeyTestScheduler(clock: clock)
      final class Box { weak var rig: ServiceRig? }
      let box = Box()
      service = HotkeyService(
        effects: RecordingDesktopHotkeyEffects(),
        telemetry: HotkeyTelemetrySink(
          registrationFailed: { _, _, _, _ in },
          pressed: { _, _, _, _, action, _ in box.rig?.actions.append(action) }),
        uptime: clock.uptime, scheduler: timers.scheduler)
      box.rig = self
      service.recordingMode = .pushToTalk
      service.toggleKeyCode = 0  // a chord, delivered through Carbon
      service.onStartRecording = { [weak self] in
        self?.starts += 1
        return .recording("session-\(self?.starts ?? 0)")
      }
      service.onLockRequested = { [weak self] _ in
        self?.published += 1
        return .published
      }
    }
    func carbon(_ isPress: Bool, _ t: TimeInterval, id: UInt32 = 1) {
      clock.now = 500 + t
      service.handleCarbonHotkey(id: id, isRelease: !isPress, timestamp: 500 + t)
    }
  }

  @Test("a reset made by an earlier effect of a batch drops that batch's later effects")
  func resetInsideABatchDropsItsLaterEffects() async {
    let rig = ServiceRig()
    defer { rig.service.stop() }
    rig.carbon(true, 0)
    await rig.service.awaitInFlightStartForTesting()
    rig.carbon(false, 0.125)  // lone-tap wait pending
    // The second press's batch is [resolved, lockIntent]: stop the service when the resolution
    // applies, so the lock intent behind it must not run.
    var stopped = false
    rig.service.onDebounceResolvedForTesting = { [weak service = rig.service] in
      guard !stopped else { return }
      stopped = true
      service?.stop()
    }
    rig.carbon(true, 0.25)
    #expect(stopped)
    #expect(rig.actions == ["start"])  // no `lock` row
    #expect(rig.published == 0)
  }

  @Test("a fresh press made during a reset's own drain keeps its start eligible")
  func freshPressDuringResetSurvivesTheReset() async {
    let rig = ServiceRig()
    defer { rig.service.stop() }
    rig.carbon(true, 0)
    await rig.service.awaitInFlightStartForTesting()
    rig.carbon(false, 0.125)  // lone-tap wait pending
    // Escape cancel resets; the reset's drain reports the cancelled wait, and that callback
    // presses the record key again: attempt 2 starts inside the reset.
    var pressed = false
    rig.service.onDebounceResolvedForTesting = { [weak rig] in
      guard let rig, !pressed else { return }
      pressed = true
      rig.carbon(true, 1.0)
    }
    rig.carbon(true, 0.9, id: 3)  // cancel hotkey
    #expect(pressed)
    await rig.service.awaitInFlightStartForTesting()
    #expect(rig.starts == 2)
    // Attempt 2 is still the executing attempt: a quick release and a second press lock it.
    rig.carbon(false, 1.125)
    rig.carbon(true, 1.25)
    #expect(rig.published == 1)
  }

  @Test("a queued press reports the key and mode it was decided under")
  func pressCarriesItsDecisionConfiguration() {
    let rig = Rig()
    rig.background(true, 0)  // decided under Right Option, push-to-talk
    rig.engine.configure(bindings: Self.bindings(record: .keyboard(keyCode: 0, modifiers: [.control])), mode: .toggle)
    var captured: (UInt16, RecordingMode)?
    rig.sink.onBatch = { batch in
      for case .press(let press) in batch.effects { captured = (press.keyCode, press.mode) }
    }
    rig.engine.drainForTesting()
    #expect(captured?.0 == ModifierKeyCodes.rightOption)
    #expect(captured?.1 == .pushToTalk)
  }

  @Test("a replaced lone-tap wait that fires anyway does nothing")
  func staleTimerFireIsIgnored() {
    let fires = OSAllocatedUnfairLock<[@Sendable () -> Void]>(initialState: [])
    let clock = HotkeyTestClock(500)
    let engine = RecordGestureEngine(
      binding: .keyboard(keyCode: ModifierKeyCodes.rightOption, modifiers: []),
      mode: .pushToTalk, clock: clock.uptime,
      scheduler: { _, fire in
        fires.withLock { $0.append(fire) }
        // Cancelling does nothing: the fire still runs, as a handler already executing would.
        return RecordGestureEngine.TimerHandle(cancel: {})
      })
    let sink = Sink()
    engine.setSink { @MainActor batch, valid in sink.record(batch, valid: valid) }
    func at(_ t: TimeInterval) -> RecordGesture.InputTime {
      .accepting(stamp: 500 + t, handled: 500 + t)
    }
    engine.ingestOnMain(isPress: true, input: at(0))
    engine.ingestOnMain(isPress: false, input: at(0.125))  // wait 1
    engine.ingestOnMain(isPress: true, input: at(0.25))  // lock: wait 1 retired
    let captured = fires.withLock { $0 }
    #expect(captured.count == 1)
    clock.now = 501
    captured.first?()  // the retired wait fires anyway
    engine.drainForTesting()
    #expect(sink.validNames == ["start", "quickRelease", "resolved", "lockIntent"])
    #expect(engine.snapshot.isLocked)
  }


  // MARK: - Listener admission (#3544 P3)

  /// The shipped bindings with record on `record` (bare Right Option, the rig's engine, unless
  /// given) and `cancel`.
  private static func bindings(
    record: ShortcutBinding = .keyboard(keyCode: ModifierKeyCodes.rightOption, modifiers: []),
    cancel: ShortcutBinding = ShortcutRole.cancel.defaultBinding
  ) -> ShortcutBindings {
    var b = ShortcutBindings.shipped
    b.record = record
    b.cancel = cancel
    return b
  }

  private static let rightCommand: UInt16 = 54

  /// A listener record input on a worker thread, classified under the engine's current
  /// generation unless one is given.
  private static func listener(
    _ rig: Rig, _ isPress: Bool, _ t: TimeInterval, key: UInt16 = ModifierKeyCodes.rightOption,
    generation: UInt64? = nil, installation: UInt64 = 7
  ) -> RecordGestureEngine.ListenerRefusal? {
    let engine = rig.engine
    let input = rig.at(t)
    let generation = generation ?? engine.listenerConfigurationGeneration
    let result = OSAllocatedUnfairLock<RecordGestureEngine.ListenerRefusal?>(initialState: nil)
    offMain {
      rig.clock.now = 500 + t
      let refusal = engine.ingestFromListener(
        keyCode: key, isPress: isPress, input: input, generation: generation,
        installation: installation)
      result.withLock { $0 = refusal }
    }
    return result.withLock { $0 }
  }

  // MARK: - Other-key dismissal (#3544 P4, D2)

  /// Another key at `t` after an unlocked push-to-talk press at 0, both by their own event times.
  private static func dismissOutcome(at t: TimeInterval) -> (dismissed: Bool, names: [String]) {
    let rig = Rig()
    rig.engine.openListenerAdmission(installation: 7)
    #expect(Self.listener(rig, true, 0) == nil)
    let dismissed = rig.engine.otherKeyFromListener(input: rig.at(t), installation: 7)
    #expect(Self.listener(rig, false, 3) == (dismissed ? .unownedRelease : nil))
    rig.engine.drainForTesting()
    return (dismissed, rig.sink.validNames)
  }

  @Test("another key below 1000 ms dismisses; at or above 1000 ms it is ignored and release stops")
  func otherKeyWindowBoundary() {
    let below = Self.dismissOutcome(at: 0.999)
    #expect(below.dismissed)
    #expect(below.names == ["start", "dismiss"], "the dismissed hold's release still stopped")
    for late in [1.0, 1.5] {
      let outcome = Self.dismissOutcome(at: late)
      #expect(!outcome.dismissed, "a key at \(late) s dismissed")
      #expect(outcome.names == ["start", "holdStop"])
    }
  }

  @Test("another key never dismisses a locked take, a toggle-mode take or a released key")
  func otherKeyOnlyDismissesAnUnlockedHeldPress() {
    // Locked: a double tap, then another key 0.3 s after the first press.
    let locked = Rig()
    locked.engine.openListenerAdmission(installation: 7)
    _ = Self.listener(locked, true, 0)
    _ = Self.listener(locked, false, 0.1)
    _ = Self.listener(locked, true, 0.2)
    #expect(locked.engine.snapshot.isLocked)
    #expect(!locked.engine.otherKeyFromListener(input: locked.at(0.3), installation: 7))
    // Toggle mode: the listener owns no press at all.
    let toggle = Rig()
    toggle.engine.configure(
      bindings: ShortcutBindings.shipped, mode: .toggle)
    toggle.engine.openListenerAdmission(installation: 7)
    #expect(!toggle.engine.otherKeyFromListener(input: toggle.at(0.1), installation: 7))
    // Released before the other key: nothing held to dismiss.
    let released = Rig()
    released.engine.openListenerAdmission(installation: 7)
    _ = Self.listener(released, true, 0)
    _ = Self.listener(released, false, 0.6)
    #expect(!released.engine.otherKeyFromListener(input: released.at(0.7), installation: 7))
    // A stale installation's key changes nothing.
    let stale = Rig()
    stale.engine.openListenerAdmission(installation: 7)
    _ = Self.listener(stale, true, 0)
    #expect(!stale.engine.otherKeyFromListener(input: stale.at(0.2), installation: 6))
  }

  @Test("after a dismissal the record key's next press starts a fresh attempt")
  func dismissalThenFreshStart() {
    let rig = Rig()
    rig.engine.openListenerAdmission(installation: 7)
    _ = Self.listener(rig, true, 0)
    #expect(rig.engine.otherKeyFromListener(input: rig.at(0.2), installation: 7))
    #expect(Self.listener(rig, false, 0.4) == .unownedRelease)
    #expect(Self.listener(rig, true, 2) == nil)
    rig.engine.drainForTesting()
    let starts = rig.sink.delivered.filter { $0.name == "start" && $0.valid }.map(\.attempt)
    #expect(starts.count == 2, "delivered: \(rig.sink.delivered)")
    #expect(Set(starts).count == 2, "the fresh press reused the dismissed attempt")
  }

  @Test("listener input from a closed or earlier installation is refused and changes nothing")
  func staleInstallationIsRefused() {
    let rig = Rig()
    #expect(Self.listener(rig, true, 0) == .staleInstallation)  // nothing open yet
    rig.engine.openListenerAdmission(installation: 8)
    #expect(Self.listener(rig, true, 0, installation: 7) == .staleInstallation)
    rig.engine.closeListenerAdmission()
    #expect(Self.listener(rig, true, 0, installation: 8) == .staleInstallation)
    rig.engine.drainForTesting()
    #expect(rig.sink.delivered.isEmpty)
    #expect(rig.engine.snapshot.isHeld == false)
    #expect(rig.engine.listenerRefusals[.staleInstallation] == 3)
  }

  @Test("a press classified before a rebind is refused; a wrong key and a chord binding are too")
  func stalePressesAreRefused() {
    let rig = Rig()
    rig.engine.openListenerAdmission(installation: 7)
    let before = rig.engine.listenerConfigurationGeneration
    rig.engine.configure(bindings: Self.bindings(record: .keyboard(keyCode: ModifierKeyCodes.leftOption, modifiers: [])), mode: .pushToTalk)
    #expect(rig.engine.listenerConfigurationGeneration != before)
    #expect(
      Self.listener(rig, true, 0, key: ModifierKeyCodes.leftOption, generation: before)
        == .staleGeneration)
    #expect(Self.listener(rig, true, 0, key: ModifierKeyCodes.rightOption) == .wrongKey)
    rig.engine.configure(bindings: Self.bindings(record: .keyboard(keyCode: ModifierKeyCodes.leftOption, modifiers: [])), mode: .toggle)
    #expect(
      Self.listener(rig, true, 0, key: ModifierKeyCodes.leftOption) == .notListenerBinding)
    rig.engine.configure(bindings: Self.bindings(record: .keyboard(keyCode: 15, modifiers: [.command])), mode: .pushToTalk)
    #expect(Self.listener(rig, true, 0, key: 15) == .notListenerBinding)
    rig.engine.drainForTesting()
    #expect(rig.sink.delivered.isEmpty)
    #expect(rig.engine.snapshot.isHeld == false)
  }

  @Test("a release with no admitted press from that key is refused, never rematched")
  func unownedReleaseIsRefused() {
    let rig = Rig()
    rig.engine.openListenerAdmission(installation: 7)
    #expect(Self.listener(rig, false, 0) == .unownedRelease)
    // A main-path press does own its key, but a different key's release still finds nothing.
    rig.main(true, 0.1)
    #expect(Self.listener(rig, false, 1, key: ModifierKeyCodes.leftOption) == .unownedRelease)
    #expect(rig.engine.snapshot.isHeld)
    #expect(rig.engine.listenerRefusals[.unownedRelease] == 2)
  }

  @Test("an unchanged configure keeps the generation, and the held key's release still stops")
  func repeatedConfigureKeepsTheHold() {
    let rig = Rig()
    rig.engine.openListenerAdmission(installation: 7)
    let generation = rig.engine.listenerConfigurationGeneration
    #expect(Self.listener(rig, true, 0) == nil)
    rig.engine.configure(bindings: Self.bindings(record: .keyboard(keyCode: ModifierKeyCodes.rightOption, modifiers: [])), mode: .pushToTalk)
    rig.engine.configure(bindings: Self.bindings(cancel: ShortcutRole.cancel.defaultBinding), mode: .pushToTalk)
    #expect(rig.engine.listenerConfigurationGeneration == generation)
    #expect(Self.listener(rig, false, 1, generation: generation) == nil)
    rig.engine.drainForTesting()
    #expect(rig.sink.validNames == ["start", "holdStop"])
  }

  @Test("after an actual rebind, the held key's release still ends its own hold")
  func releaseFollowsItsPressAcrossARebind() {
    let rig = Rig()
    rig.engine.openListenerAdmission(installation: 7)
    #expect(Self.listener(rig, true, 0) == nil)
    let old = rig.engine.listenerConfigurationGeneration
    rig.engine.configure(bindings: Self.bindings(record: .keyboard(keyCode: ModifierKeyCodes.leftOption, modifiers: [])), mode: .pushToTalk)
    #expect(Self.listener(rig, false, 1, generation: old) == nil)
    rig.engine.drainForTesting()
    #expect(rig.sink.validNames == ["start", "holdStop"])
    #expect(rig.engine.snapshot.isHeld == false)
  }

  @Test("a listener cancel is refused unless armed, on the bare cancel key, and not the record key")
  func cancelAdmission() {
    let rig = Rig()
    rig.engine.openListenerAdmission(installation: 7)
    rig.engine.configure(bindings: Self.bindings(cancel: .keyboard(keyCode: Self.rightCommand, modifiers: [])), mode: .pushToTalk)
    let g = rig.engine.listenerConfigurationGeneration
    #expect(
      rig.engine.cancelFromListener(keyCode: Self.rightCommand, generation: g, installation: 7)
        == .cancelNotArmed)
    rig.engine.setCancelArmed(true)
    #expect(
      rig.engine.cancelFromListener(
        keyCode: ModifierKeyCodes.leftOption, generation: g, installation: 7) == .wrongKey)
    #expect(
      rig.engine.cancelFromListener(keyCode: Self.rightCommand, generation: g &- 1, installation: 7)
        == .staleGeneration)
    // Record wins a tie: cancel bound to the record key is never cancel.
    rig.engine.configure(bindings: Self.bindings(cancel: .keyboard(keyCode: ModifierKeyCodes.rightOption, modifiers: [])), mode: .pushToTalk)
    #expect(
      rig.engine.cancelFromListener(
        keyCode: ModifierKeyCodes.rightOption, generation: rig.engine.listenerConfigurationGeneration,
        installation: 7) == .wrongKey)
    rig.engine.drainForTesting()
    #expect(rig.sink.delivered.isEmpty)
  }

  /// A service whose record key is bare Right Option in push-to-talk and whose cancel key is bare
  /// Right Command, with the listener installed, counting starts, cancels and lock publications.
  @MainActor private final class CancelRig {
    let clock = HotkeyTestClock(500)
    let timers: HotkeyTestScheduler
    let service: HotkeyService
    var starts = 0
    var published = 0
    let cancels = HotkeyGlobeKeyTests.CallbackWaiter()
    var cancelCount = 0
    /// While set, the cancel callback waits here after it is entered, as a real teardown does.
    var cancelGate: CheckedContinuation<Void, Never>?
    var holdCancel = false
    init() {
      timers = HotkeyTestScheduler(clock: clock)
      service = HotkeyService(
        effects: RecordingDesktopHotkeyEffects(), uptime: clock.uptime,
        scheduler: timers.scheduler)
      service.recordingMode = .pushToTalk
      service.cancelKeyCode = RecordGestureEngineTests.rightCommand
      service.cancelModifiers = []
      service.onStartRecording = { [unowned self] in
        starts += 1
        return .recording("session-\(starts)")
      }
      service.onLockRequested = { [unowned self] _ in
        published += 1
        return .published
      }
      service.onCancelRecording = { [unowned self] in
        cancelCount += 1
        cancels.note()
        if holdCancel {
          await withCheckedContinuation { cancelGate = $0 }
        }
      }
      service.start()
    }
    var engine: RecordGestureEngine { service.recordGestureEngineForTesting }
    func record(_ isPress: Bool, _ t: TimeInterval) {
      clock.now = 500 + t
      let refusal = engine.ingestFromListener(
        keyCode: ModifierKeyCodes.rightOption, isPress: isPress,
        input: .accepting(stamp: 500 + t, handled: 500 + t),
        generation: engine.listenerConfigurationGeneration, installation: engine.listenerInstallation ?? 0)
      #expect(refusal == nil)
    }
    func cancel() {
      let refusal = engine.cancelFromListener(
        keyCode: RecordGestureEngineTests.rightCommand, generation: engine.listenerConfigurationGeneration,
        installation: engine.listenerInstallation ?? 0)
      #expect(refusal == nil)
    }
  }

  @Test("a cancel made before a new press, while main is busy, cancels only the older dictation")
  func queuedCancelSparesTheNextHeldAttempt() async {
    let rig = CancelRig()
    defer { rig.service.stop() }
    rig.record(true, 0)
    rig.engine.drainForTesting()
    await rig.service.awaitInFlightStartForTesting()
    rig.service.setCancelHotkeyEnabled(true)
    // Main withheld: cancel, release the record key, press it again; all decided before main runs.
    rig.cancel()
    rig.record(false, 2.0)
    rig.record(true, 2.5)
    rig.engine.drainForTesting()
    await rig.cancels.wait(until: 1)
    await rig.service.awaitInFlightStartForTesting()
    #expect(rig.cancelCount == 1)
    #expect(rig.starts == 2)
    #expect(rig.service.isModifierHeld)
    // The newer attempt is fully alive on main: a quick release and a second press lock it.
    rig.record(false, 2.625)
    rig.record(true, 2.75)
    rig.engine.drainForTesting()
    #expect(rig.published == 1)
    #expect(rig.service.isRecordingLocked)
  }

  @Test("a cancel of a hands-free dictation makes the next press a new dictation, not a stop")
  func queuedCancelOfALockedAttemptStartsFresh() async {
    let rig = CancelRig()
    defer { rig.service.stop() }
    rig.record(true, 0)
    rig.engine.drainForTesting()
    await rig.service.awaitInFlightStartForTesting()
    rig.record(false, 0.125)
    rig.record(true, 0.25)
    rig.engine.drainForTesting()
    #expect(rig.service.isRecordingLocked)
    rig.record(false, 0.375)
    rig.engine.drainForTesting()
    rig.service.setCancelHotkeyEnabled(true)
    rig.cancel()
    rig.record(true, 3.0)
    rig.engine.drainForTesting()
    await rig.cancels.wait(until: 1)
    await rig.service.awaitInFlightStartForTesting()
    #expect(rig.cancelCount == 1)
    #expect(rig.starts == 2)
    #expect(rig.service.isRecordingLocked == false)
    #expect(rig.service.isModifierHeld)
  }

  @Test("the next dictation starts only after a listener cancel has finished tearing down")
  func nextStartWaitsForTheCancel() async throws {
    let rig = CancelRig()
    defer { rig.service.stop() }
    rig.record(true, 0)
    rig.engine.drainForTesting()
    await rig.service.awaitInFlightStartForTesting()
    rig.service.setCancelHotkeyEnabled(true)
    rig.holdCancel = true
    let reachedWait = HotkeyGlobeKeyTests.CallbackWaiter()
    rig.service.onListenerCancellationWaitForTesting = { reachedWait.note() }
    rig.cancel()
    rig.record(false, 2.0)
    rig.record(true, 2.5)
    rig.engine.drainForTesting()
    await rig.cancels.wait(until: 1)
    // The start has reached its wait while the cancel is still tearing down.
    await reachedWait.wait(until: 1)
    #expect(rig.starts == 1)
    let gate = try #require(rig.cancelGate)
    rig.cancelGate = nil
    gate.resume()
    await rig.service.awaitInFlightStartForTesting()
    #expect(rig.starts == 2)
    rig.record(false, 2.625)
    rig.record(true, 2.75)
    rig.engine.drainForTesting()
    #expect(rig.published == 1)
    #expect(rig.service.isRecordingLocked)
  }

  @Test("a listener press classified before an explicit reset is refused after it")
  func resetRefusesAClassifiedPress() {
    let rig = Rig()
    rig.engine.openListenerAdmission(installation: 7)
    let classified = rig.engine.listenerConfigurationGeneration
    rig.engine.reset()
    #expect(Self.listener(rig, true, 0, generation: classified) == .staleGeneration)
    rig.engine.drainForTesting()
    #expect(rig.sink.validNames.contains("start") == false)
    #expect(rig.engine.snapshot.isHeld == false)
  }

  @Test("a queued listener cancel is still delivered after its attempt is refused")
  func cancelSurvivesItsAttemptsRefusal() {
    let rig = Rig()
    rig.engine.openListenerAdmission(installation: 7)
    rig.engine.configure(bindings: Self.bindings(cancel: .keyboard(keyCode: Self.rightCommand, modifiers: [])), mode: .pushToTalk)
    #expect(Self.listener(rig, true, 0) == nil)
    rig.engine.drainForTesting()
    let attempt = rig.sink.delivered.first { $0.name == "start" }?.attempt ?? 0
    rig.engine.setCancelArmed(true)
    #expect(
      rig.engine.cancelFromListener(
        keyCode: Self.rightCommand, generation: rig.engine.listenerConfigurationGeneration,
        installation: 7) == nil)
    rig.engine.reset(attempt: attempt)
    rig.engine.drainForTesting()
    #expect(rig.sink.validNames.filter { $0 == "cancel" }.count == 1)
  }

  // MARK: - Which lone-tap waits hop to main (#3544 P3)

  /// An engine as the service builds it: waits armed by main-thread input hop to main.
  private func hoppingEngine(_ clock: HotkeyTestClock, _ timers: HotkeyTestScheduler, _ sink: Sink)
    -> RecordGestureEngine
  {
    let engine = RecordGestureEngine(
      binding: .keyboard(keyCode: ModifierKeyCodes.rightOption, modifiers: []),
      mode: .pushToTalk, clock: clock.uptime, scheduler: timers.scheduler, hopsMainInput: true)
    engine.setSink { @MainActor batch, valid in sink.record(batch, valid: valid) }
    engine.openListenerAdmission(installation: 7)
    return engine
  }

  /// #3544 P4 C2: a press admitted without stated evidence must not authorize a reading to end
  /// it, and a release decided from a reading about one attempt never ends a newer attempt.
  @Test("unstated press evidence never authorizes a reading release, and stale readings miss newer attempts")
  func pressRecoveryEvidenceGuardsReadingReleases() {
    let clock = HotkeyTestClock(500)
    let timers = HotkeyTestScheduler(clock: clock)
    let sink = Sink()
    let engine = hoppingEngine(clock, timers, sink)
    let generation = engine.listenerConfigurationGeneration
    let key = ModifierKeyCodes.rightOption
    // Omitted evidence: not readable, and the orphaned-hold release refuses it.
    engine.ingestFromListener(
      keyCode: key, isPress: true, input: .accepting(stamp: 500, handled: 500),
      generation: generation, installation: 7)
    let unstated = engine.ownedListenerPress
    #expect(unstated?.recovery == .notReadable)
    engine.closeListenerAdmission()
    #expect(
      engine.releaseOrphanedListenerPress(
        unstated!, input: .accepting(stamp: 501, handled: 501)) == false)
    #expect(engine.ownedListenerKey == key)
    engine.forgetHeld()
    // A readable press, read about, then replaced by a newer press of the same key.
    engine.openListenerAdmission(installation: 7)
    engine.ingestFromListener(
      keyCode: key, isPress: true, input: .accepting(stamp: 502, handled: 502),
      generation: generation, installation: 7, recovery: .readable)
    let first = engine.ownedListenerPress!
    #expect(first.recovery == .readable)
    engine.ingestFromListener(
      keyCode: key, isPress: false, input: .accepting(stamp: 503, handled: 503),
      generation: generation, installation: 7)
    clock.now = 510
    engine.ingestFromListener(
      keyCode: key, isPress: true, input: .accepting(stamp: 510, handled: 510),
      generation: generation, installation: 7, recovery: .readable)
    let second = engine.ownedListenerPress!
    #expect(second.attemptID != first.attemptID)
    // The stale reading's release, through the listener path and the orphaned path: both refused.
    #expect(
      engine.ingestFromListener(
        keyCode: key, isPress: false, input: .accepting(stamp: nil, handled: 511),
        generation: generation, installation: 7, onlyAttempt: first.attemptID) == .unownedRelease)
    engine.closeListenerAdmission()
    #expect(
      engine.releaseOrphanedListenerPress(first, input: .accepting(stamp: nil, handled: 512))
        == false)
    #expect(engine.ownedListenerPress == second)
  }

  @Test("a listener-fed lone tap's wait decides on the timer queue, never waiting for main")
  func listenerWaitDoesNotHop() {
    let clock = HotkeyTestClock(500)
    let timers = HotkeyTestScheduler(clock: clock)
    let sink = Sink()
    let engine = hoppingEngine(clock, timers, sink)
    let generation = engine.listenerConfigurationGeneration
    engine.ingestFromListener(
      keyCode: ModifierKeyCodes.rightOption, isPress: true,
      input: .accepting(stamp: 500, handled: 500), generation: generation, installation: 7)
    clock.now = 500.125
    engine.ingestFromListener(
      keyCode: ModifierKeyCodes.rightOption, isPress: false,
      input: .accepting(stamp: 500.125, handled: 500.125), generation: generation,
      installation: 7)
    clock.now = 500.625
    Self.offMain { timers.fireDue() }
    // Main has run nothing since the fire: the stop is already decided and queued.
    engine.drainForTesting()
    #expect(sink.validNames.contains("loneTapStop"))
  }

  @Test("a main-fed lone tap's wait still queues behind main (Carbon chords until P5)")
  func mainWaitHops() async {
    let clock = HotkeyTestClock(500)
    let timers = HotkeyTestScheduler(clock: clock)
    let sink = Sink()
    let engine = hoppingEngine(clock, timers, sink)
    engine.ingestOnMain(isPress: true, input: .accepting(stamp: 500, handled: 500))
    clock.now = 500.125
    engine.ingestOnMain(isPress: false, input: .accepting(stamp: 500.125, handled: 500.125))
    clock.now = 500.625
    Self.offMain { timers.fireDue() }
    engine.drainForTesting()
    #expect(sink.validNames.contains("loneTapStop") == false, "decided before main's turn")
    await ListenerKeyboard.mainTurn()
    engine.drainForTesting()
    #expect(sink.validNames.contains("loneTapStop"))
  }

  // MARK: - Configuration and ownership (#3544 P3)

  @Test("the listener never reads half of a configuration change")
  func classificationIsNeverHalfConfigured() {
    let rig = Rig()
    let a = Self.bindings(
      record: .keyboard(keyCode: ModifierKeyCodes.rightOption, modifiers: []),
      cancel: .keyboard(keyCode: Self.rightCommand, modifiers: []))
    let b = Self.bindings(
      record: .keyboard(keyCode: ModifierKeyCodes.leftOption, modifiers: []),
      cancel: .keyboard(keyCode: 53, modifiers: []))
    let engine = rig.engine
    let seen = OSAllocatedUnfairLock<[RecordGestureEngine.ListenerClassification]>(initialState: [])
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInteractive).async {
      for _ in 0..<2000 { seen.withLock { $0.append(engine.listenerClassification()) } }
      done.signal()
    }
    for i in 0..<2000 {
      engine.configure(bindings: i.isMultiple(of: 2) ? a : b, mode: i.isMultiple(of: 2) ? .pushToTalk : .toggle)
    }
    // deadline-fallback: bound the reader's own completion signal so a regression fails, not hangs.
    #expect(done.wait(timeout: .now() + 5) == .success)
    for c in seen.withLock({ $0 }) {
      let pair = (c.configuration.bindings, c.mode)
      #expect((pair.0 == a && pair.1 == .pushToTalk) || (pair.0 == b && pair.1 == .toggle)
        || (pair.0 == Self.bindings() && pair.1 == .pushToTalk))
    }
  }

  @Test("a chord press admitted through main is never the listener's to release")
  func carbonPressIsNotListenerOwned() {
    let rig = Rig()
    rig.engine.openListenerAdmission(installation: 7)
    rig.main(true, 0)
    #expect(rig.engine.snapshot.isHeld)
    #expect(rig.engine.ownedListenerKey == nil, "the watchdog would release a Carbon chord")
    #expect(Self.listener(rig, false, 1) == .unownedRelease)
    #expect(rig.engine.snapshot.isHeld)
  }
}
