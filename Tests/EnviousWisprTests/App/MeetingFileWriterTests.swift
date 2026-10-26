import Dispatch
import EnviousWisprAppKitTestSupport
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #4102: the meeting writer's bounded operations, through both waiting adapters (`runBounded`
/// blocks its caller, `runWithin` suspends it). When this is wrong, Delete All or quit hangs past
/// its deadline, deletes History after a mark that never landed, or loses a late result.
/// Serialized: it holds the one process-wide writer queue with a gate.
@Suite("Meeting file writer bounded operations (#4102)", .serialized, .tags(.productOutcome))
struct MeetingFileWriterTests {

  struct Failed: Error {}

  /// A gate on the writer queue: `entered` is signalled when the gated block starts, and the
  /// block waits for `release` (a fallback bound releases it if a test fails first).
  final class Gate: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func hold() {
      entered.signal()
      // settle: deadline fallback only; a failing test must not strand the shared queue.
      _ = release.wait(timeout: .now() + 10)
    }

    /// Waits off the main actor for the gated block to start: the block's own signal decides.
    func waitEntered() async -> Bool {
      // settle: deadline fallback around the block's `entered` signal.
      await Task.detached { [entered] in MeetingFileWriterTests.waitBlocking(entered) == .success }
        .value
    }
  }

  /// A synchronous wait, called only from a detached task so no actor is blocked.
  // settle: deadline fallback around a semaphore the subject or gate signals.
  nonisolated static func waitBlocking(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + 10)
  }

  private static func writer() -> MeetingFileWriter {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-4102-writer-\(UUID().uuidString)", isDirectory: true)
    return MeetingFileWriter(store: MeetingStore(root: dir), writeRecord: { _, _ in })
  }

  /// Everything queued before this has drained (FIFO), without blocking the caller.
  private static func drained(_ writer: MeetingFileWriter) async {
    _ = try? await writer.run { _ in }
  }

  private final class Counter: Sendable {
    let value = OSAllocatedUnfairLock(initialState: 0)
    func add() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
  }

  private final class LateBox: Sendable {
    let results = OSAllocatedUnfairLock<[Bool]>(initialState: [])
    let arrived = DispatchSemaphore(value: 0)
    func record(_ result: Result<Void, Error>) {
      results.withLock {
        $0.append((try? result.get()) != nil)
      }
      arrived.signal()
    }
    func waitArrived() async -> Bool {
      // settle: deadline fallback around the late callback's own signal.
      await Task.detached { [arrived] in MeetingFileWriterTests.waitBlocking(arrived) == .success }
        .value
    }
  }

  /// The two adapters behind one call shape. `runBounded` blocks, so it runs off the main actor.
  enum Adapter: CaseIterable, CustomStringConvertible {
    case blocking, suspending
    var description: String { self == .blocking ? "runBounded" : "runWithin" }

    func run(
      _ writer: MeetingFileWriter, until deadline: DispatchTime,
      _ work: @escaping @Sendable (MeetingStore) throws -> Void,
      late: @escaping @Sendable (Result<Void, Error>) -> Void
    ) async -> MeetingFileWriter.BoundedOutcome {
      switch self {
      case .blocking:
        return await Task.detached { writer.runBounded(until: deadline, work, late: late) }.value
      case .suspending:
        return await writer.runWithin(until: deadline, work, late: late)
      }
    }
  }

  private static func describe(_ outcome: MeetingFileWriter.BoundedOutcome) -> String {
    switch outcome {
    case .finished(.success): return "finished(success)"
    case .finished(.failure): return "finished(failure)"
    case .withdrawn: return "withdrawn"
    case .stillRunning: return "stillRunning"
    }
  }

  @Test(
    "work that finishes in time answers its result, success or failure", arguments: Adapter.allCases
  )
  func finishedInTime(adapter: Adapter) async {
    let writer = Self.writer()
    let late = Counter()
    let ok = await adapter.run(writer, until: .now() + 5, { _ in }, late: { _ in late.add() })
    #expect(Self.describe(ok) == "finished(success)")
    let bad = await adapter.run(
      writer, until: .now() + 5, { _ in throw Failed() }, late: { _ in late.add() })
    #expect(Self.describe(bad) == "finished(failure)")
    await Self.drained(writer)
    #expect(late.count == 0, "nothing is reported late")
    #expect(writer.pendingCount == 0)
  }

  @Test(
    "work still queued at the deadline is withdrawn and never runs", arguments: Adapter.allCases)
  func queuedWithdrawal(adapter: Adapter) async throws {
    let writer = Self.writer()
    let gate = Gate()
    MeetingFileWriter.queue.async { gate.hold() }
    try #require(await gate.waitEntered(), "the queue was never held")
    let ran = Counter()
    let late = Counter()
    let outcome = await adapter.run(
      writer, until: .now() + .milliseconds(50), { _ in ran.add() }, late: { _ in late.add() })
    #expect(Self.describe(outcome) == "withdrawn")
    #expect(writer.pendingCount == 1, "the withdrawn block has not drained yet")
    gate.release.signal()
    await Self.drained(writer)
    #expect(ran.count == 0, "withdrawn work never runs")
    #expect(late.count == 0)
    #expect(writer.pendingCount == 0, "counted down exactly once")
  }

  @Test(
    "work running at the deadline is abandoned and reports late exactly once",
    arguments: Adapter.allCases)
  func runningAbandoned(adapter: Adapter) async throws {
    for fails in [false, true] {
      let writer = Self.writer()
      let gate = Gate()
      let late = LateBox()
      let caller = Task {
        await adapter.run(
          writer, until: .now() + .milliseconds(200),
          { _ in
            gate.hold()
            if fails { throw Failed() }
          }, late: late.record)
      }
      try #require(await gate.waitEntered(), "the work never started")
      let outcome = await caller.value
      #expect(Self.describe(outcome) == "stillRunning", "fails: \(fails)")
      #expect(late.results.withLock { $0 }.isEmpty, "nothing late before it ends")
      gate.release.signal()
      try #require(await late.waitArrived(), "the late result never came")
      await Self.drained(writer)
      #expect(late.results.withLock { $0 } == [!fails], "exactly one late result, the real one")
      #expect(writer.pendingCount == 0)
    }
  }

  /// The deadline against completion in each order, on one operation driven directly: no queue,
  /// no clock, so the boundary both adapters rely on is exact.
  @Test("the deadline judged before, during and after the work answers withdrawn, stillRunning or finished")
  func deadlineAgainstCompletion() {
    let store = MeetingStore(
      root: TestTemporaryDirectory.url
        .appendingPathComponent("ew-4102-op-\(UUID().uuidString)", isDirectory: true))

    // After: the work finished first, so the deadline answers its result and nothing is late.
    for fails in [false, true] {
      let op = MeetingFileWriter.BoundedOperation()
      let pending = OSAllocatedUnfairLock(initialState: 1)
      let inTime = Counter()
      let late = Counter()
      op.execute(
        store: store, pending: pending, { _ in if fails { throw Failed() } },
        inTime: { inTime.add() }, late: { _ in late.add() })
      #expect(Self.describe(op.deadlinePassed()) == (fails ? "finished(failure)" : "finished(success)"))
      #expect(inTime.count == 1 && late.count == 0 && pending.withLock { $0 } == 0)
    }

    // Before: withdrawn while queued, so the work never runs and nothing is reported.
    do {
      let op = MeetingFileWriter.BoundedOperation()
      let pending = OSAllocatedUnfairLock(initialState: 1)
      let ran = Counter()
      let reported = Counter()
      #expect(Self.describe(op.deadlinePassed()) == "withdrawn")
      op.execute(
        store: store, pending: pending, { _ in ran.add() },
        inTime: { reported.add() }, late: { _ in reported.add() })
      #expect(ran.count == 0 && reported.count == 0 && pending.withLock { $0 } == 0)
    }

    // During: abandoned while running, so the real result goes to `late` once, never `inTime`.
    for fails in [false, true] {
      let op = MeetingFileWriter.BoundedOperation()
      let pending = OSAllocatedUnfairLock(initialState: 1)
      let inTime = Counter()
      let late = LateBox()
      let during = OSAllocatedUnfairLock<String?>(initialState: nil)
      op.execute(
        store: store, pending: pending,
        { _ in
          let outcome = Self.describe(op.deadlinePassed())
          during.withLock { $0 = outcome }
          if fails { throw Failed() }
        }, inTime: { inTime.add() }, late: late.record)
      #expect(during.withLock { $0 } == "stillRunning")
      #expect(Self.describe(op.deadlinePassed()) == "stillRunning", "a second look changes nothing")
      #expect(inTime.count == 0 && late.results.withLock { $0 } == [!fails])
      #expect(pending.withLock { $0 } == 0)
    }
  }

  @MainActor
  private final class ResponsivenessProbe {
    var callerSettled = false
    var ran = false
  }

  /// The write itself needs the main actor to finish, so a caller that blocked the main actor
  /// would hold it to the deadline and answer `stillRunning`. The deadline is only a fallback;
  /// `queuedWithdrawal` covers the deadline answering while the queue is held.
  @MainActor
  @Test("main-actor work releases a running write before its suspended caller settles")
  func suspendingDeadlineWhileHeld() async throws {
    let writer = Self.writer()
    let gate = Gate()
    defer { gate.release.signal() }
    let probe = ResponsivenessProbe()
    let late = Counter()

    let outcome = await writer.runWithin(
      until: .now() + 5,
      { _ in
        Task { @MainActor in
          probe.ran = true
          #expect(probe.callerSettled == false)
          gate.release.signal()
        }
        gate.hold()
      },
      late: { _ in late.add() })

    probe.callerSettled = true
    #expect(probe.ran)
    #expect(Self.describe(outcome) == "finished(success)")
    await Self.drained(writer)
    #expect(late.count == 0)
    #expect(writer.pendingCount == 0)
  }
}
