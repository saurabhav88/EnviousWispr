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
    func fireAll() {
      let fires = pending.withLock { pending -> [@Sendable () -> Void] in
        defer { pending = [] }
        return pending
      }
      for fire in fires { fire() }
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
      onAbandonedReadReturned: onReturn)
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
}
