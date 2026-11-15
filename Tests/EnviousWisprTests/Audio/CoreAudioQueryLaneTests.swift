import Foundation
import Testing
import os

@testable import EnviousWisprAudio

/// #4021: a Core Audio read stuck inside a third-party driver must never freeze the app.
/// When these fail, the user sees a frozen app or a device list that never recovers.
@Suite("Core Audio query lane", .tags(.productOutcome))
struct CoreAudioQueryLaneTests {
  /// Deadlines the test fires itself, so no test waits for time to pass.
  final class ManualDeadlines: Sendable {
    private let pending = OSAllocatedUnfairLock(initialState: [@Sendable () -> Void]())
    /// Fires when the subject registers its first deadline, so a test never fires a deadline
    /// the subject has not scheduled yet.
    let registered = Signal()
    func schedule(_: Duration, _ fire: @escaping @Sendable () -> Void) {
      pending.withLock { $0.append(fire) }
      registered.fire()
    }
    func takeAll() -> [@Sendable () -> Void] {
      pending.withLock { pending -> [@Sendable () -> Void] in
        defer { pending = [] }
        return pending
      }
    }
    func fireAll() {
      for fire in takeAll() { fire() }
    }
  }

  /// A one-shot signal with a fallback so a broken subject fails the test instead of hanging it.
  final class Signal: Sendable {
    private let stream = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    init() {
      let continuation = stream.continuation
      // deadline-fallback: releases a broken fixture; this is not a latency assertion.
      DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
        continuation.yield(false)
        continuation.finish()
      }
    }
    func fire() {
      stream.continuation.yield(true)
      stream.continuation.finish()
    }
    func wait() async -> Bool {
      for await value in stream.stream { return value }
      return false
    }
  }

  /// Waits for `task` through a subject-completion signal with a fallback, so a subject that
  /// never resumes its caller fails the test instead of hanging it on `Task.value`.
  private func boundedValue<T: Sendable>(_ task: Task<T, Never>, done: Signal) async -> T? {
    guard await done.wait() else {
      Issue.record("the subject never resumed its caller")
      return nil
    }
    return await task.value
  }

  /// Records whether a gated fixture was released by the test or expired on its fallback.
  final class Gate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let expired = OSAllocatedUnfairLock(initialState: false)
    func open() { semaphore.signal() }
    func block() {
      // deadline-fallback: releases a broken fixture; this is not a latency assertion.
      if semaphore.wait(timeout: .now() + 10) == .timedOut { expired.withLock { $0 = true } }
    }
    var didExpire: Bool { expired.withLock { $0 } }
  }

  struct Returned: Sendable, Equatable {
    let name: String
  }

  private func makeLane(
    deadlines: ManualDeadlines,
    onReturn: @escaping @Sendable (String, Duration) -> Void = { _, _ in }
  ) -> CoreAudioQueryLane {
    CoreAudioQueryLane(
      label: "test.coreaudio.query",
      scheduleDeadline: { bound, fire in deadlines.schedule(bound, fire) },
      now: { ContinuousClock.now },
      hooks: .init(abandonedReadReturned: { name, after, _ in onReturn(name, after) }))
  }

  @Test("A healthy read returns its value and leaves the lane free")
  func healthyRead() async {
    let deadlines = ManualDeadlines()
    let lane = makeLane(deadlines: deadlines)
    let outcome = await lane.bounded("device_snapshot") { 42 }
    guard case .value(let value) = outcome else {
      Issue.record("expected a value, got \(outcome)")
      return
    }
    #expect(value == 42)
    #expect(lane.isBusy == false)
    // A deadline firing after the value already resumed the caller must be a no-op.
    deadlines.fireAll()
  }

  @Test("A stuck read times out, keeps the lane busy, refuses new reads, then recovers")
  func stuckReadIsContainedAndRecovers() async {
    let deadlines = ManualDeadlines()
    let returned = OSAllocatedUnfairLock(initialState: [Returned]())
    let returnedSignal = Signal()
    let lane = makeLane(deadlines: deadlines) { name, _ in
      returned.withLock { $0.append(Returned(name: name)) }
      returnedSignal.fire()
    }
    let gate = Gate()
    defer { gate.open() }
    let entered = Signal()
    let firstDone = Signal()

    let stuck = Task {
      let outcome = await lane.bounded("device_snapshot") { () -> Int in
        entered.fire()
        gate.block()
        return 1
      }
      firstDone.fire()
      return outcome
    }
    #expect(await entered.wait(), "the worker entered its blocking read")
    #expect(await deadlines.registered.wait(), "the subject scheduled its deadline")
    // The read is blocked; the main actor still runs.
    let mainActorRan = await MainActor.run { true }
    #expect(mainActorRan)

    deadlines.fireAll()
    guard let first = await boundedValue(stuck, done: firstDone) else { return }
    guard case .timedOut = first else {
      Issue.record("expected .timedOut, got \(first)")
      return
    }
    #expect(lane.isBusy, "a caller giving up must not clear busy")

    let extraReads = OSAllocatedUnfairLock(initialState: 0)
    let refused = await lane.bounded("device_snapshot") { () -> Int in
      extraReads.withLock { $0 += 1 }
      return 2
    }
    guard case .busy = refused else {
      Issue.record("expected .busy, got \(refused)")
      return
    }

    let available = Signal()
    let notifiedEarly = OSAllocatedUnfairLock(initialState: false)
    let released = OSAllocatedUnfairLock(initialState: false)
    lane.whenAvailable {
      if released.withLock({ $0 }) == false { notifiedEarly.withLock { $0 = true } }
      available.fire()
    }
    #expect(notifiedEarly.withLock { $0 } == false, "a busy lane must not notify before the worker returns")

    released.withLock { $0 = true }
    gate.open()
    #expect(await returnedSignal.wait(), "the abandoned read reported its late return")
    #expect(await available.wait(), "the availability waiter ran after the worker returned")
    #expect(lane.isBusy == false)
    #expect(returned.withLock { $0 } == [Returned(name: "device_snapshot")])
    #expect(extraReads.withLock { $0 } == 0, "a busy refusal never runs or queues its reader")
    #expect(notifiedEarly.withLock { $0 } == false)
    #expect(gate.didExpire == false, "the test released the worker; the fixture fallback did not")

    let healthy = await lane.bounded("device_snapshot") { 3 }
    guard case .value(let value) = healthy else {
      Issue.record("expected recovery to a value, got \(healthy)")
      return
    }
    #expect(value == 3)
  }

  @Test("Subscribing while the lane is free runs the callback at once")
  func availabilityWhenFree() {
    let lane = makeLane(deadlines: ManualDeadlines())
    let ran = OSAllocatedUnfairLock(initialState: false)
    lane.whenAvailable { ran.withLock { $0 = true } }
    #expect(ran.withLock { $0 })
  }

  @Test("A healthy read wakes a waiter that subscribed while it ran, and reports no late return")
  func healthyCompletionWakesWaiters() async {
    let deadlines = ManualDeadlines()
    let lateReturns = OSAllocatedUnfairLock(initialState: 0)
    let lane = makeLane(deadlines: deadlines) { _, _ in lateReturns.withLock { $0 += 1 } }
    let gate = Gate()
    defer { gate.open() }
    let entered = Signal()
    let readDone = Signal()
    let read = Task {
      let outcome = await lane.bounded("choice_validation") { () -> String in
        entered.fire()
        gate.block()
        return "uid"
      }
      readDone.fire()
      return outcome
    }
    #expect(await entered.wait())
    let available = Signal()
    let notifiedEarly = OSAllocatedUnfairLock(initialState: false)
    let released = OSAllocatedUnfairLock(initialState: false)
    lane.whenAvailable {
      if released.withLock({ $0 }) == false { notifiedEarly.withLock { $0 = true } }
      available.fire()
    }
    #expect(notifiedEarly.withLock { $0 } == false, "a busy lane must not notify before the worker returns")
    released.withLock { $0 = true }
    gate.open()
    guard let outcome = await boundedValue(read, done: readDone) else { return }
    #expect(gate.didExpire == false)
    #expect(lane.isBusy == false)
    guard case .value(let value) = outcome else {
      Issue.record("expected a value, got \(outcome)")
      return
    }
    #expect(value == "uid")
    #expect(await available.wait())
    #expect(lateReturns.withLock { $0 } == 0, "a read that answered in time is not a late return")
    deadlines.fireAll()  // a deadline after completion must not resume the caller again
  }

  /// Every hook call, in order, for the reporting tests.
  final class HookLog: Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: [String]())
    private let completedSignals = OSAllocatedUnfairLock(initialState: [String: Signal]())
    let returned = Signal()
    func record(_ call: String) { calls.withLock { $0.append(call) } }
    /// Fires once the first read named `name` has reported completion (hooks run after the
    /// caller is resumed, so a test must wait for this rather than read the log at once).
    func completed(_ name: String) -> Signal {
      completedSignals.withLock { signals in
        if let signal = signals[name] { return signal }
        let signal = Signal()
        signals[name] = signal
        return signal
      }
    }
    var all: [String] { calls.withLock { $0 } }
    var hooks: CoreAudioQueryLane.Hooks {
      .init(
        timedOut: { name, bound in self.record("timedOut \(name) \(bound)") },
        abandonedReadReturned: { name, after, bound in
          self.record("recovered \(name) after \(after) bound \(bound)")
          self.returned.fire()
        },
        completed: { name, duration in
          self.record("completed \(name) \(duration)")
          self.completed(name).fire()
        },
        debugStallFired: { name, stall in self.record("stall \(name) \(stall)") })
    }
  }

  /// A clock the test advances, so reported durations are exact.
  final class StepClock: Sendable {
    private let base = ContinuousClock.now
    private let offset = OSAllocatedUnfairLock(initialState: Duration.zero)
    func advance(_ by: Duration) { offset.withLock { $0 += by } }
    var now: ContinuousClock.Instant { base + offset.withLock { $0 } }
  }

  @Test("Reporting: one timeout however often the timer fires, nothing for busy or healthy reads, one recovery with the original bound")
  func reportingHooks() async {
    let deadlines = ManualDeadlines()
    let clock = StepClock()
    let log = HookLog()
    let lane = CoreAudioQueryLane(
      label: "test.coreaudio.hooks", scheduleDeadline: { deadlines.schedule($0, $1) },
      now: { clock.now }, hooks: log.hooks)

    // The healthy read runs on its own lane (same log), so this test's deadline signal belongs
    // only to the stuck read below.
    let healthyLane = CoreAudioQueryLane(
      label: "test.coreaudio.hooks.healthy", scheduleDeadline: { _, _ in }, now: { clock.now },
      hooks: log.hooks)
    _ = await healthyLane.bounded("device_snapshot", bound: .seconds(2)) { 1 }
    #expect(await log.completed("device_snapshot").wait())
    #expect(log.all == ["completed device_snapshot 0.0 seconds"], "a healthy read reports only its duration")

    let gate = Gate()
    defer { gate.open() }
    let entered = Signal()
    let done = Signal()
    let stuck = Task {
      let outcome = await lane.bounded("choice_validation", bound: .seconds(3)) { () -> Int in
        entered.fire()
        gate.block()
        return 2
      }
      done.fire()
      return outcome
    }
    #expect(await entered.wait())
    #expect(await deadlines.registered.wait())
    // Fire the stored deadline twice: the single-resume claim lets only the first count.
    let fires = deadlines.takeAll()
    for fire in fires { fire() }
    for fire in fires { fire() }
    guard let first = await boundedValue(stuck, done: done), case .timedOut = first else {
      Issue.record("expected .timedOut")
      return
    }
    _ = await lane.bounded("device_snapshot") { 3 }  // busy: refused, reports nothing

    clock.advance(.milliseconds(4500))
    gate.open()
    #expect(await log.returned.wait())
    #expect(await log.completed("choice_validation").wait())
    #expect(gate.didExpire == false)
    #expect(
      log.all == [
        "completed device_snapshot 0.0 seconds",
        "timedOut choice_validation 3.0 seconds",
        "recovered choice_validation after 4.5 seconds bound 3.0 seconds",
        "completed choice_validation 4.5 seconds",
      ])
  }

  #if DEBUG
    @Test("DEBUG stall: the next admitted read stalls once (and times out), the read after it does not")
    func debugStallIsOneShot() async {
      let deadlines = ManualDeadlines()
      let log = HookLog()
      let stallGate = Gate()
      defer { stallGate.open() }
      let stallStarted = Signal()
      let lane = CoreAudioQueryLane(
        label: "test.coreaudio.stall", scheduleDeadline: { deadlines.schedule($0, $1) },
        now: { ContinuousClock.now }, hooks: log.hooks,
        stallExecutor: { _ in
          stallStarted.fire()
          stallGate.block()
        })
      lane.armStallForNextRead(.seconds(10))

      let done = Signal()
      let stalled = Task {
        let outcome = await lane.bounded("device_snapshot") { 1 }
        done.fire()
        return outcome
      }
      #expect(await stallStarted.wait(), "the armed stall ran on the admitted read")
      #expect(await deadlines.registered.wait())
      deadlines.fireAll()
      guard let first = await boundedValue(stalled, done: done), case .timedOut = first else {
        Issue.record("expected the stalled read to time out")
        return
      }
      stallGate.open()
      #expect(await log.returned.wait())

      let next = await lane.bounded("device_snapshot") { 2 }
      guard case .value(let value) = next else {
        Issue.record("expected the next read to run normally, got \(next)")
        return
      }
      #expect(value == 2)
      #expect(log.all.filter { $0.hasPrefix("stall ") } == ["stall device_snapshot 10.0 seconds"])
      #expect(stallGate.didExpire == false)
    }
  #endif
}
