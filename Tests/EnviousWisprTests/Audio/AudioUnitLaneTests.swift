import Foundation
import Testing
import os

@testable import EnviousWisprAudio

/// #4601 §3.1: the audio-unit lane. When these fail, the user sees a frozen app at record start
/// or microphone release, a stuck-microphone notice on a healthy Mac, or a microphone left open
/// after a start that gave up. Deadlines and clock are the test's own; no hardware.
@Suite("Audio unit lane — #4601", .tags(.productOutcome))
struct AudioUnitLaneTests {

  /// Timers the test fires itself, keyed by their delay.
  final class ManualTimers: Sendable {
    private struct Entry {
      let delay: Duration
      let fire: @Sendable () -> Void
    }
    private let pending = OSAllocatedUnfairLock(initialState: [Entry]())
    private let watchers = OSAllocatedUnfairLock(initialState: [(Duration, Signal)]())

    func schedule(_ delay: Duration, _ fire: @escaping @Sendable () -> Void) {
      pending.withLock { $0.append(Entry(delay: delay, fire: fire)) }
      let ready = watchers.withLock { watchers -> [Signal] in
        let hit = watchers.filter { $0.0 == delay }.map(\.1)
        watchers.removeAll { $0.0 == delay }
        return hit
      }
      for signal in ready { signal.fire() }
    }

    /// Resolves once a timer with `delay` has been scheduled (now or later).
    func scheduled(_ delay: Duration) async -> Bool {
      let signal = Signal()
      let already = pending.withLock { pending -> Bool in
        if pending.contains(where: { $0.delay == delay }) { return true }
        watchers.withLock { $0.append((delay, signal)) }
        return false
      }
      return already ? true : await signal.wait()
    }

    /// Fires (and removes) every pending timer with `delay`.
    func fire(_ delay: Duration) {
      let due = pending.withLock { pending -> [Entry] in
        let due = pending.filter { $0.delay == delay }
        pending.removeAll { $0.delay == delay }
        return due
      }
      for entry in due { entry.fire() }
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

  /// Blocks a lane job until the test opens it.
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

  /// Hook and work recorder.
  final class Log: Sendable {
    private let entries = OSAllocatedUnfairLock(initialState: [String]())
    func add(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
    func count(_ prefix: String) -> Int { all.filter { $0.hasPrefix(prefix) }.count }
  }

  static let base = ContinuousClock.now

  private func makeLane(_ timers: ManualTimers, _ log: Log, stalls: Log? = nil) -> AudioUnitLane {
    AudioUnitLane(
      label: "test.audio.unit-lane",
      schedule: { delay, fire in timers.schedule(delay, fire) },
      now: { Self.base },
      hooks: .init(
        operationTimedOut: { id, name, _ in log.add("timedOut:\(name)#\(id)") },
        operationRecovered: { id, name, _, _ in log.add("recovered:\(name)#\(id)") },
        completed: { _, name, _ in log.add("completed:\(name)") },
        debugStallFired: { _, name, _ in log.add("stall:\(name)") }),
      stallExecutor: { _ in stalls?.add("stalled") })
  }

  /// Starts a blocking read named `name` and returns once it is running on the lane.
  private func startBlockingRead(
    _ lane: AudioUnitLane, _ name: String, gate: Gate, log: Log
  ) async -> Task<AudioUnitLane.Outcome<Int>, Never>? {
    let entered = Signal()
    let task = Task {
      await lane.run(name) { () -> Int in
        log.add("ran:\(name)")
        entered.fire()
        gate.block()
        return 1
      }
    }
    guard await entered.wait() else {
      Issue.record("\(name) never started")
      return nil
    }
    return task
  }

  @Test("a healthy open hands its value to the caller and disposes nothing")
  func healthyOpen() async {
    let timers = ManualTimers()
    let log = Log()
    let lane = makeLane(timers, log)

    let outcome = await lane.open(
      "microphone_start", attempt: 1, deadline: Self.base + .seconds(5), { 7 },
      disposeLate: { _ in log.add("disposed") })

    guard case .value(let value) = outcome else {
      Issue.record("expected a value, got \(outcome)")
      return
    }
    #expect(value == 7)
    #expect(log.count("disposed") == 0)
    #expect(lane.isWedged == false)
  }

  @Test("ordinary contention waits its turn instead of being refused")
  func contentionWaits() async {
    let timers = ManualTimers()
    let log = Log()
    let lane = makeLane(timers, log)
    let gate = Gate()
    defer { gate.open() }
    guard let first = await startBlockingRead(lane, "probe", gate: gate, log: log) else { return }

    let second = Task { await lane.run("route", deadline: Self.base + .milliseconds(500)) { 2 } }
    #expect(await timers.scheduled(.milliseconds(500)), "the second caller is waiting")
    #expect(lane.isWedged == false)
    gate.open()

    guard case .value = await first.value, case .value(let two) = await second.value else {
      Issue.record("both healthy jobs must return values")
      return
    }
    #expect(two == 2)
    #expect(
      log.all.filter { $0.hasPrefix("completed:") } == ["completed:probe", "completed:route"])
  }

  @Test(
    "a queued job whose caller left runs no native work and wedges nothing",
    arguments: ["deadline", "cancel"])
  func withdrawnQueuedJobRunsNothing(how: String) async {
    let timers = ManualTimers()
    let log = Log()
    let lane = makeLane(timers, log)
    let gate = Gate()
    defer { gate.open() }
    guard let first = await startBlockingRead(lane, "probe", gate: gate, log: log) else { return }

    let queued = Task {
      await lane.open(
        "microphone_start", attempt: 9, deadline: Self.base + .seconds(2),
        { () -> Int in
          log.add("ran:open")
          return 3
        }, disposeLate: { _ in log.add("disposed") })
    }
    #expect(await timers.scheduled(.seconds(2)))
    if how == "deadline" { timers.fire(.seconds(2)) } else { queued.cancel() }
    let outcome = await queued.value
    switch (how, outcome) {
    case ("deadline", .timedOut), ("cancel", .abandoned): break
    default: Issue.record("unexpected outcome \(outcome) for \(how)")
    }
    gate.open()
    _ = await first.value
    await lane.drainForTesting()

    #expect(log.count("ran:open") == 0)
    #expect(log.count("disposed") == 0)
    #expect(log.count("timedOut:") == 0)
    #expect(log.count("recovered:") == 0)
    #expect(lane.isWedged == false)
  }

  @Test("a job past its own limit wedges the lane: new starts are refused, release still queues")
  func wedgedLaneRefusesStartsUntilRecovery() async {
    let timers = ManualTimers()
    let log = Log()
    let lane = makeLane(timers, log)
    let gate = Gate()
    defer { gate.open() }
    guard let stuck = await startBlockingRead(lane, "probe", gate: gate, log: log) else { return }
    #expect(await timers.scheduled(AudioUnitLane.readLimit))

    timers.fire(AudioUnitLane.readLimit)
    #expect(lane.isWedged)
    #expect(log.count("timedOut:probe") == 1)

    let refused = await lane.open(
      "microphone_start", attempt: 2, deadline: Self.base + .seconds(5),
      { () -> Int in
        log.add("ran:open")
        return 1
      }, disposeLate: { _ in })
    guard case .wedged = refused else {
      Issue.record("expected an immediate refusal, got \(refused)")
      return
    }
    lane.retire { log.add("ran:retire") }
    let available = Signal()
    lane.whenAvailable { available.fire() }

    gate.open()
    _ = await stuck.value
    #expect(await available.wait(), "availability follows the queued release")
    #expect(log.count("ran:open") == 0)
    #expect(log.count("recovered:probe") == 1)
    #expect(log.count("timedOut:probe") == 1, "one timeout per stalled job")
    let order = log.all.filter { $0.hasPrefix("recovered:probe") || $0 == "ran:retire" }
      .map { $0.hasPrefix("recovered:probe") ? "recovered:probe" : $0 }
    #expect(order == ["recovered:probe", "ran:retire"])
    #expect(lane.isWedged == false)
  }

  @Test(
    "an open whose caller left is disposed by the lane before later jobs and before availability",
    arguments: ["deadline", "abandon"])
  func lateOpenIsDisposed(how: String) async {
    let timers = ManualTimers()
    let log = Log()
    let lane = makeLane(timers, log)
    let gate = Gate()
    defer { gate.open() }
    let entered = Signal()

    let open = Task {
      await lane.open(
        "microphone_start", attempt: 4, deadline: Self.base + .seconds(2),
        { () -> Int in
          entered.fire()
          gate.block()
          return 11
        }, disposeLate: { value in log.add("disposed:\(value)") })
    }
    #expect(await entered.wait())
    #expect(await timers.scheduled(.seconds(2)))
    if how == "deadline" { timers.fire(.seconds(2)) } else { lane.abandon(attempt: 4) }
    let outcome = await open.value
    switch (how, outcome) {
    case ("deadline", .timedOut), ("abandon", .abandoned): break
    default: Issue.record("unexpected outcome \(outcome) for \(how)")
    }
    lane.retire { log.add("ran:retire") }
    let available = Signal()
    lane.whenAvailable { available.fire() }

    gate.open()
    #expect(await available.wait())
    #expect(log.all.filter { !$0.hasPrefix("completed:") } == ["disposed:11", "ran:retire"])
    #expect(log.count("recovered:") == 0, "no stall happened: the open never passed its limit")
  }

  @Test("a release queued before an open finishes first")
  func releaseBeforeOpen() async {
    let timers = ManualTimers()
    let log = Log()
    let lane = makeLane(timers, log)
    let gate = Gate()
    defer { gate.open() }
    let entered = Signal()

    lane.retire {
      entered.fire()
      gate.block()
      log.add("ran:retire")
    }
    #expect(await entered.wait())
    let open = Task {
      await lane.open(
        "microphone_start", attempt: 5, deadline: Self.base + .seconds(5),
        { () -> Int in
          log.add("ran:open")
          return 1
        }, disposeLate: { _ in })
    }
    #expect(await timers.scheduled(.seconds(5)))
    gate.open()
    guard case .value = await open.value else {
      Issue.record("a healthy release must not refuse the open")
      return
    }
    #expect(log.all.filter { $0.hasPrefix("ran:") } == ["ran:retire", "ran:open"])
  }

  @Test("waiting for a release at quit is bounded by its deadline")
  func retireAndWaitIsBounded() {
    let lane = AudioUnitLane(label: "test.audio.unit-lane.quit")
    let gate = Gate()
    // A stuck release: the wait must give up at its deadline.
    let finished = lane.retireAndWait(deadline: ContinuousClock.now + .milliseconds(20)) {
      gate.block()
    }
    #expect(finished == false)
    gate.open()
    // A healthy release completes inside a generous deadline.
    let healthy = lane.retireAndWait(deadline: ContinuousClock.now + .seconds(5)) {}
    #expect(healthy)
  }

  @Test("a stall armed for the open is consumed only by the open")
  func stallArmSelectsItsOperation() async {
    let timers = ManualTimers()
    let log = Log()
    let stalls = Log()
    let lane = makeLane(timers, log, stalls: stalls)
    lane.armStall(for: .open, .seconds(3))

    _ = await lane.run("probe") { 1 }
    lane.retire {}
    await lane.drainForTesting()
    #expect(stalls.all.isEmpty, "a read and a release leave the arm in place")

    _ = await lane.open(
      "microphone_start", attempt: 6, deadline: Self.base + .seconds(5), { 1 },
      disposeLate: { _ in })
    #expect(stalls.all == ["stalled"])
    #expect(log.count("stall:microphone_start") == 1)
  }

  @MainActor
  @Test("the main actor keeps running while a lane job is blocked")
  func mainActorRunsDuringBlockedJob() async {
    let timers = ManualTimers()
    let log = Log()
    let lane = makeLane(timers, log)
    let gate = Gate()
    defer { gate.open() }
    guard let stuck = await startBlockingRead(lane, "probe", gate: gate, log: log) else { return }

    var mainWork = 0
    for _ in 0..<3 {
      await Task.yield()
      mainWork += 1
    }
    #expect(mainWork == 3)
    gate.open()
    _ = await stuck.value
  }
}
