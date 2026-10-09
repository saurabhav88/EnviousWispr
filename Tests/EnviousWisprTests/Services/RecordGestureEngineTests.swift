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
    rig.engine.configure(binding: .keyboard(keyCode: 0, modifiers: [.control]), mode: .toggle)
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

  #if DEBUG
    @Test("the debug observer reports the decisions made and changes none of them")
    @MainActor
    func observerReportsWithoutChangingDecisions() {
      let seen = OSAllocatedUnfairLock<[GestureOutcome]>(initialState: [])
      let observed = Rig()
      observed.engine.setObserver { o in seen.withLock { $0.append(o.outcome) } }
      let plain = Rig()
      for rig in [observed, plain] {
        rig.main(true, 0)
        rig.main(false, 0.125)
        rig.main(true, 0.25)
        rig.main(false, 0.375)
      }
      #expect(
        seen.withLock { $0 } == [
          .start, .quickRelease, .lockIntent, .loneTapCancelled, .releaseSuppressedLocked,
        ])
      #expect(observed.sink.validNames == plain.sink.validNames)
      #expect(observed.sink.validNames == ["start", "quickRelease", "resolved", "lockIntent"])
    }

    @Test("the debug observer reports a timer's stop with its quick release and first press")
    @MainActor
    func observerReportsTimerStop() {
      let seen = OSAllocatedUnfairLock<[GestureObservation]>(initialState: [])
      let rig = Rig()
      rig.engine.setObserver { o in seen.withLock { $0.append(o) } }
      rig.main(true, 0)
      rig.main(false, 0.125)
      rig.clock.now = 500.625
      rig.fireDueOffMain()
      let timer = seen.withLock { $0 }.last
      #expect(timer?.kind == .timer)
      #expect(timer?.outcome == .loneTapStop)
      #expect(timer?.occurred == 500.125)
      #expect(timer?.attemptStartOccurred == 500)
      #expect(timer?.deadline == 500.625)
    }

    @Test("a reset's retired wait is reported as retired, not as a press cancelling it")
    @MainActor
    func observerReportsRetiredWait() {
      let seen = OSAllocatedUnfairLock<[GestureOutcome]>(initialState: [])
      let rig = Rig()
      rig.engine.setObserver { o in seen.withLock { $0.append(o.outcome) } }
      rig.main(true, 0)
      rig.main(false, 0.125)
      rig.engine.reset()
      #expect(seen.withLock { $0 }.last == .loneTapRetired)
    }

    @Test("a wait scheduled before a rebind is reported under the key it was scheduled for")
    @MainActor
    func observerKeepsTheTimersOwnKey() {
      let seen = OSAllocatedUnfairLock<[GestureObservation]>(initialState: [])
      let rig = Rig()
      rig.engine.setObservationGeneration(7)
      rig.engine.setObserver { o in seen.withLock { $0.append(o) } }
      rig.main(true, 0)
      rig.main(false, 0.125)
      rig.engine.configure(
        binding: .keyboard(keyCode: ModifierKeyCodes.leftOption, modifiers: []), mode: .pushToTalk)
      rig.engine.setObservationGeneration(8)
      rig.clock.now = 500.625
      rig.fireDueOffMain()
      let all = seen.withLock { $0 }
      let timer = all.last
      #expect(timer?.kind == .timer)
      #expect(timer?.keyCode == ModifierKeyCodes.rightOption)
      #expect(timer?.generation == 8)
      #expect(all.first?.generation == 7)
      #expect(all.map(\.sequence) == [1, 2, 3])
    }
  #endif
}
