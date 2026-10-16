import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprTranscribeCpp

/// #3735 plan §3.2a: the executor that owns every transcribe.cpp call.
///
/// **What the user sees when this fails:** two engine runs overlap on the GPU (garbled text or
/// a native crash), the preview delays or corrupts the final dictation, a cancelled take still
/// pastes text, or a model is freed while it is still decoding (crash).
///
/// The native boundary is a controlled fake: every run blocks inside the fake until the test
/// releases it or the executor aborts it, and the fake records how many runs are inside at once
/// across ALL its sessions (the occupancy the executor must keep at 1).
@Suite("transcribe.cpp executor ownership (#3735)", .serialized, .tags(.productOutcome))
struct TranscribeCppExecutorTests {

  // MARK: - Tests

  @Test("two models' heart requests never run at once and both complete once")
  func crossModelSerialization() async throws {
    let native = FakeNative()
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let a = try await executor.load(modelPath: "a", lane: .heart)
    let b = try await executor.load(modelPath: "b", lane: .heart)

    let first = Task {
      try await executor.transcribe(a, samples: [1], language: "en", lane: .heart)
    }
    await native.waitForArrivals(1)
    let second = Task {
      try await executor.transcribe(b, samples: [2], language: "en", lane: .heart)
    }
    // The second request is queued, not inside native code.
    await native.waitForSubmitted(executor: executor, heartQueued: 1)
    #expect(native.inside == 1)
    native.release("a")
    #expect(try await native.bounded(first).text == "a")
    await native.waitForArrivals(2)
    native.release("b")
    #expect(try await native.bounded(second).text == "b")
    #expect(native.peakInside == 1)
    #expect(native.log == ["enter a", "exit a", "enter b", "exit b"])
    let counters = await executor.counters
    #expect(counters.completed >= 2)
  }

  @Test("heart requests run in submission order")
  func heartFIFO() async throws {
    let native = FakeNative()
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let m = try await executor.load(modelPath: "m", lane: .heart)
    let t1 = Task { try await executor.transcribe(m, samples: [1], language: nil, lane: .heart) }
    await native.waitForArrivals(1)
    let t2 = Task { try await executor.transcribe(m, samples: [2], language: nil, lane: .heart) }
    await native.waitForSubmitted(executor: executor, heartQueued: 1)
    let t3 = Task { try await executor.transcribe(m, samples: [3], language: nil, lane: .heart) }
    await native.waitForSubmitted(executor: executor, heartQueued: 2)
    for _ in 1...3 {
      await native.waitForInside()
      native.release("m")
    }
    _ = try await (native.bounded(t1), native.bounded(t2), native.bounded(t3))
    #expect(native.samplesSeen == [[1], [2], [3]])
    #expect(native.peakInside == 1)
  }

  @Test(
    "a heart request drops queued previews, aborts the running preview, and runs after it returns")
  func heartPreemptsPreview() async throws {
    let native = FakeNative()
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let heart = try await executor.load(modelPath: "turbo", lane: .heart)
    let preview = try await executor.load(modelPath: "small", lane: .preview)

    let p1 = Task {
      try await executor.transcribe(preview, samples: [1], language: nil, lane: .preview)
    }
    await native.waitForArrivals(1)
    let p2 = Task {
      try await executor.transcribe(preview, samples: [2], language: nil, lane: .preview)
    }
    await native.waitForSubmitted(executor: executor, previewQueued: 1)

    let h = Task {
      try await executor.transcribe(heart, samples: [9], language: "en", lane: .heart)
    }
    // The queued preview ends at once, without ever entering native code.
    await #expect(throws: TranscribeCppExecutor.ExecutorError.preempted) {
      try await native.bounded(p2)
    }
    // The running preview was aborted out of band and returns; only then does the heart run.
    await #expect(throws: TranscribeCppExecutor.ExecutorError.preempted) {
      try await native.bounded(p1)
    }
    await native.waitForArrivals(2)
    native.release("turbo")
    #expect(try await native.bounded(h).text == "turbo")
    #expect(
      native.log == ["enter small", "abort small", "exit small", "enter turbo", "exit turbo"])
    #expect(native.peakInside == 1)
  }

  @Test("a preview is refused while heart work is queued or running")
  func previewRefusedDuringHeart() async throws {
    let native = FakeNative()
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let heart = try await executor.load(modelPath: "turbo", lane: .heart)
    let preview = try await executor.load(modelPath: "small", lane: .preview)
    let h = Task { try await executor.transcribe(heart, samples: [1], language: nil, lane: .heart) }
    await native.waitForArrivals(1)
    await #expect(throws: TranscribeCppExecutor.ExecutorError.heartBusy) {
      _ = try await executor.transcribe(preview, samples: [1], language: nil, lane: .preview)
    }
    native.release("turbo")
    _ = try await native.bounded(h)
    #expect(native.log == ["enter turbo", "exit turbo"])
  }

  @Test("a preempted preview that still returns success publishes nothing")
  func preemptedSuccessIsDiscarded() async throws {
    let native = FakeNative(ignoresAbort: ["small"])
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let heart = try await executor.load(modelPath: "turbo", lane: .heart)
    let preview = try await executor.load(modelPath: "small", lane: .preview)
    let p = Task {
      try await executor.transcribe(preview, samples: [1], language: nil, lane: .preview)
    }
    await native.waitForArrivals(1)
    let h = Task { try await executor.transcribe(heart, samples: [1], language: nil, lane: .heart) }
    await native.waitForAbort("small")
    native.release("small")  // the native call returns SUCCESS despite the abort
    await #expect(throws: TranscribeCppExecutor.ExecutorError.preempted) {
      try await native.bounded(p)
    }
    await native.waitForArrivals(2)
    native.release("turbo")
    _ = try await native.bounded(h)
    #expect(await executor.counters.discardedResults == 1)
  }

  @Test("cancelling a queued request ends it at once and leaves the running one alone")
  func cancelQueued() async throws {
    let native = FakeNative()
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let m = try await executor.load(modelPath: "m", lane: .heart)
    let running = Task {
      try await executor.transcribe(m, samples: [1], language: nil, lane: .heart)
    }
    await native.waitForArrivals(1)
    let queued = Task {
      try await executor.transcribe(m, samples: [2], language: nil, lane: .heart)
    }
    await native.waitForSubmitted(executor: executor, heartQueued: 1)
    queued.cancel()
    await #expect(throws: TranscribeCppExecutor.ExecutorError.cancelled) {
      try await native.bounded(queued)
    }
    #expect(native.abortCount("m") == 0)
    native.release("m")
    #expect(try await native.bounded(running).text == "m")
    #expect(native.samplesSeen == [[1]], "the cancelled request never reached native code")
  }

  @Test(
    "cancelling a running request releases the caller now but holds occupancy until the native return"
  )
  func cancelRunningHoldsOccupancy() async throws {
    let native = FakeNative(ignoresAbort: ["m"])
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let m = try await executor.load(modelPath: "m", lane: .heart)
    let running = Task {
      try await executor.transcribe(m, samples: [1], language: nil, lane: .heart)
    }
    await native.waitForArrivals(1)
    running.cancel()
    await #expect(throws: TranscribeCppExecutor.ExecutorError.cancelled) {
      try await native.bounded(running)
    }
    #expect(native.abortCount("m") == 1)
    // Native code is still inside; the next request must wait for it.
    let next = Task { try await executor.transcribe(m, samples: [2], language: nil, lane: .heart) }
    await native.waitForSubmitted(executor: executor, heartQueued: 1)
    #expect(native.inside == 1)
    native.release("m")  // the abandoned run returns (late result discarded)
    await native.waitForArrivals(2)
    native.release("m")
    #expect(try await native.bounded(next).text == "m")
    #expect(await executor.counters.discardedResults == 1)
    #expect(native.peakInside == 1)
  }

  @Test("an aborted run leaves no abort behind: the next request on the same model runs clean")
  func abortResetBeforeReuse() async throws {
    let native = FakeNative()
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let m = try await executor.load(modelPath: "m", lane: .heart)
    let first = Task { try await executor.transcribe(m, samples: [1], language: nil, lane: .heart) }
    await native.waitForArrivals(1)
    first.cancel()
    await #expect(throws: TranscribeCppExecutor.ExecutorError.cancelled) {
      try await native.bounded(first)
    }
    // The fake aborted (it honours abort), so the native call has returned.
    await native.waitForExits(1)
    let second = Task {
      try await executor.transcribe(m, samples: [2], language: nil, lane: .heart)
    }
    await native.waitForArrivals(2)
    #expect(native.abortPending("m") == false, "a stale abort would kill this run")
    native.release("m")
    #expect(try await native.bounded(second).text == "m")
  }

  @Test("unload aborts and drains running work, frees once, coalesces, and refuses later work")
  func unloadDrainsAndCoalesces() async throws {
    let native = FakeNative()
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let m = try await executor.load(modelPath: "m", lane: .heart)
    let running = Task {
      try await executor.transcribe(m, samples: [1], language: nil, lane: .heart)
    }
    await native.waitForArrivals(1)
    let u1 = Task { await executor.unload(m) }
    let u2 = Task { await executor.unload(m) }
    try await native.bounded(u1)
    try await native.bounded(u2)
    // The run was aborted and returned BEFORE the free.
    await #expect(throws: (any Error).self) { try await native.bounded(running) }
    #expect(native.log == ["enter m", "abort m", "exit m", "close m"])
    #expect(native.closeCount("m") == 1)
    await #expect(throws: TranscribeCppExecutor.ExecutorError.modelUnavailable) {
      _ = try await executor.transcribe(m, samples: [1], language: nil, lane: .heart)
    }
    #expect(await executor.counters.freed == 1)
  }

  @Test("an unload with nothing running frees the model once")
  func unloadIdle() async throws {
    let native = FakeNative()
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    let m = try await executor.load(modelPath: "m", lane: .heart)
    try await native.bounded(Task { await executor.unload(m) })
    #expect(native.log == ["close m"])
    #expect(await executor.counters.freed == 1)
    try await native.bounded(Task { await executor.unload(m) })  // already freed: returns at once
    #expect(native.closeCount("m") == 1)
  }

  @Test(
    "an unload never loses its free when the running work returns during unload setup",
    arguments: 0..<40)
  func unloadRacingCompletion(round: Int) async throws {
    // The fake honours the abort at once, so the aborted run's completion races the
    // unload's free installation on every round.
    let native = FakeNative()
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    let a = try await executor.load(modelPath: "a", lane: .heart)
    let b = try await executor.load(modelPath: "b", lane: .heart)
    let running = Task {
      try await executor.transcribe(a, samples: [1], language: nil, lane: .heart)
    }
    await native.waitForArrivals(1)
    let unload = Task { await executor.unload(a) }
    await native.waitForAbort("a")
    // Work for another model submitted while the teardown is in progress runs after it.
    let other = Task { try await executor.transcribe(b, samples: [2], language: nil, lane: .heart) }
    try await native.bounded(unload)
    await #expect(throws: (any Error).self) { try await native.bounded(running) }
    await native.waitForArrivals(2)
    native.release("b")
    #expect(try await native.bounded(other).text == "b")
    #expect(native.closeCount("a") == 1)
    #expect(native.log == ["enter a", "abort a", "exit a", "close a", "enter b", "exit b"])
    #expect(native.peakInside == 1)
  }

  @Test("a cancelled unload caller still gets a complete teardown")
  func cancelledUnloadCaller() async throws {
    let native = FakeNative(ignoresAbort: ["m"])
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    let m = try await executor.load(modelPath: "m", lane: .heart)
    let running = Task {
      try await executor.transcribe(m, samples: [1], language: nil, lane: .heart)
    }
    await native.waitForArrivals(1)
    let unload = Task { await executor.unload(m) }
    await native.waitForAbort("m")
    unload.cancel()
    native.release("m")  // the aborted run returns; only then may the free run
    try await native.bounded(unload)
    _ = try? await native.bounded(running)
    #expect(native.log == ["enter m", "abort m", "exit m", "close m"])
    await #expect(throws: TranscribeCppExecutor.ExecutorError.modelUnavailable) {
      _ = try await executor.transcribe(m, samples: [2], language: nil, lane: .heart)
    }
  }

  @Test("an already-cancelled heart request ends at once and never interrupts the preview")
  func alreadyCancelledHeartDoesNotPreempt() async throws {
    let native = FakeNative()
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let heart = try await executor.load(modelPath: "turbo", lane: .heart)
    let preview = try await executor.load(modelPath: "small", lane: .preview)
    let p = Task {
      try await executor.transcribe(preview, samples: [1], language: nil, lane: .preview)
    }
    await native.waitForArrivals(1)
    let h = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await executor.transcribe(heart, samples: [9], language: "en", lane: .heart)
    }
    await #expect(throws: TranscribeCppExecutor.ExecutorError.cancelled) {
      try await native.bounded(h)
    }
    #expect(native.abortCount("small") == 0)
    native.release("small")
    #expect(try await native.bounded(p).text == "small")
    #expect(native.log == ["enter small", "exit small"])
  }

  @Test(
    "a cancellation racing a successful return ends the request exactly once and frees the lane",
    arguments: 0..<40)
  func cancellationRacesSuccess(round: Int) async throws {
    let native = FakeNative(ignoresAbort: ["m"])
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    let m = try await executor.load(modelPath: "m", lane: .heart)
    let racing = Task {
      try await executor.transcribe(m, samples: [1], language: nil, lane: .heart)
    }
    await native.waitForArrivals(1)
    native.release("m")
    racing.cancel()
    do {
      #expect(try await native.bounded(racing).text == "m")
    } catch let error as TranscribeCppExecutor.ExecutorError {
      #expect(error == .cancelled)
    }
    let next = Task { try await executor.transcribe(m, samples: [2], language: nil, lane: .heart) }
    await native.waitForArrivals(2)
    native.release("m")
    #expect(try await native.bounded(next).text == "m")
    #expect(native.peakInside == 1)
  }

  @Test("a cancelled load that returns late closes its orphan session exactly once")
  func cancelledLoadClosesOrphan() async throws {
    let native = FakeNative(blocksLoad: ["x"])
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    let load = Task { try await executor.load(modelPath: "x", lane: .heart) }
    await native.waitForLog("load x")
    load.cancel()
    await #expect(throws: TranscribeCppExecutor.ExecutorError.cancelled) {
      try await native.bounded(load)
    }
    native.releaseLoad("x")
    await native.waitForLog("close x")
    // The lane is free again and the orphan was closed once, before any later work.
    let m = try await executor.load(modelPath: "m", lane: .heart)
    try await native.bounded(Task { await executor.unload(m) })
    #expect(native.log == ["load x", "close x", "close m"])
  }

  @Test("a preempted preview load that returns late closes its orphan before the heart runs")
  func preemptedLoadClosesOrphan() async throws {
    let native = FakeNative(blocksLoad: ["small"])
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let heart = try await executor.load(modelPath: "turbo", lane: .heart)
    let load = Task { try await executor.load(modelPath: "small", lane: .preview) }
    await native.waitForLog("load small")
    let h = Task { try await executor.transcribe(heart, samples: [1], language: nil, lane: .heart) }
    await native.waitForSubmitted(executor: executor, heartQueued: 1)
    native.releaseLoad("small")
    await #expect(throws: TranscribeCppExecutor.ExecutorError.preempted) {
      try await native.bounded(load)
    }
    await native.waitForArrivals(1)
    native.release("turbo")
    #expect(try await native.bounded(h).text == "turbo")
    #expect(native.log == ["load small", "close small", "enter turbo", "exit turbo"])
  }

  @Test("the waiter gives up when the signal never comes (deadline control)")
  func waiterDeadlineControl() async {
    let native = FakeNative()
    await withKnownIssue("no request is ever submitted, so the arrival wait must time out") {
      await native.waitForArrivals(1, deadline: .milliseconds(200))
    }
  }

  @Test("the bounded wait gives up on a task that never completes (deadline control)")
  func boundedDeadlineControl() async {
    let native = FakeNative()
    let never = Task<Int, any Error> {
      try await Task.sleep(for: .seconds(600))  // deadline-fallback: a subject that never finishes
      return 1
    }
    defer { never.cancel() }
    await withKnownIssue("the task never completes, so the bounded wait must expire") {
      await #expect(throws: DeadlineExpired.self) {
        _ = try await native.bounded(never, deadline: .milliseconds(200))
      }
    }
  }
}

// MARK: - Fake native boundary

/// Shared state for every fake session: occupancy is measured ACROSS sessions, because the
/// executor's promise is one native call at a time for all models.
private final class FakeNative: @unchecked Sendable {
  private let lock = NSLock()
  private var _inside = 0
  private var _peak = 0
  private var _arrivals = 0
  private var _exits = 0
  private var _log: [String] = []
  private var _samples: [[Float]] = []
  private var sessions: [String: FakeSession] = [:]
  private var waiters: [(id: UUID, met: () -> Bool, resume: CheckedContinuation<Void, Never>)] = []
  let ignoresAbort: Set<String>
  /// Loads that block inside native code until `releaseLoad` (or a deadline) frees them.
  private let loadGates: [String: DispatchSemaphore]
  /// What a model's successful run returns; by default its name as text, with no segments.
  let results: [String: TranscribeCppRunResult]

  init(
    ignoresAbort: Set<String> = [], blocksLoad: Set<String> = [],
    results: [String: TranscribeCppRunResult] = [:]
  ) {
    self.ignoresAbort = ignoresAbort
    self.results = results
    self.loadGates = Dictionary(
      uniqueKeysWithValues: blocksLoad.map { ($0, DispatchSemaphore(value: 0)) })
  }

  func releaseLoad(_ name: String) { loadGates[name]?.signal() }

  var makeSession: @Sendable (String) throws -> any TranscribeCppEngineSession {
    { [self] path in
      if let gate = loadGates[path] {
        record("load \(path)")
        if !releasedAll { gate.wait() }
      }
      let session = FakeSession(name: path, native: self)
      lock.withLock { sessions[path] = session }
      return session
    }
  }

  var inside: Int { lock.withLock { _inside } }
  var peakInside: Int { lock.withLock { _peak } }
  var log: [String] { lock.withLock { _log } }
  var samplesSeen: [[Float]] { lock.withLock { _samples } }
  func abortCount(_ name: String) -> Int {
    lock.withLock { _log.filter { $0 == "abort \(name)" }.count }
  }
  func closeCount(_ name: String) -> Int {
    lock.withLock { _log.filter { $0 == "close \(name)" }.count }
  }
  func abortPending(_ name: String) -> Bool { lock.withLock { sessions[name]?.abortFlag ?? false } }

  func release(_ name: String) {
    let session = lock.withLock { sessions[name] }
    session?.gate.signal()
  }

  // Called on the executor's native queue. Counted inside the lock that also parks, so
  // "arrived" and "releasable" are published together (test-timing.md #3134).
  func enter(_ session: FakeSession, samples: [Float]) {
    lock.withLock {
      _inside += 1
      _peak = max(_peak, _inside)
      _arrivals += 1
      _log.append("enter \(session.name)")
      _samples.append(samples)
    }
    notify()
  }

  func exit(_ session: FakeSession) {
    lock.withLock {
      _inside -= 1
      _exits += 1
      _log.append("exit \(session.name)")
    }
    notify()
  }

  func record(_ line: String) {
    lock.withLock { _log.append(line) }
    notify()
  }

  private func notify() {
    lock.lock()
    let ready = waiters.filter { $0.met() }
    waiters.removeAll { $0.met() }
    lock.unlock()
    for waiter in ready { waiter.resume.resume() }
  }

  func waitForArrivals(
    _ count: Int, deadline: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    await waitUntil(deadline: deadline, sourceLocation: sourceLocation) { self._arrivals >= count }
  }

  func waitForExits(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
    await waitUntil(sourceLocation: sourceLocation) { self._exits >= count }
  }

  func waitForInside(sourceLocation: SourceLocation = #_sourceLocation) async {
    await waitUntil(sourceLocation: sourceLocation) { self._inside == 1 }
  }

  func waitForAbort(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    await waitUntil(sourceLocation: sourceLocation) { self._log.contains("abort \(name)") }
  }

  func waitForLog(_ line: String, sourceLocation: SourceLocation = #_sourceLocation) async {
    await waitUntil(sourceLocation: sourceLocation) { self._log.contains(line) }
  }

  private var _depths = TranscribeCppExecutor.QueueDepths(heart: 0, preview: 0, running: false)

  /// Subscribes to the executor's synchronous state announcements (its test seam).
  func observe(_ executor: TranscribeCppExecutor) async {
    await executor.setStateObserver { [self] depths in
      lock.withLock { _depths = depths }
      notify()
    }
  }

  /// Waits for the executor's own queue state, announced by the executor itself.
  func waitForSubmitted(
    executor: TranscribeCppExecutor, heartQueued: Int = 0, previewQueued: Int = 0,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    await waitUntil(sourceLocation: sourceLocation) {
      self._depths.heart >= heartQueued && self._depths.preview >= previewQueued
    }
  }

  private func waitUntil(
    deadline: Duration = .seconds(5), sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @escaping () -> Bool
  ) async {
    let id = UUID()
    let timeout = Task {
      try? await Task.sleep(for: deadline)  // deadline-fallback: bounds the signal wait
      self.giveUp(id, sourceLocation: sourceLocation)
    }
    await withCheckedContinuation { continuation in
      lock.lock()
      if condition() {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append((id, condition, continuation))
        lock.unlock()
      }
    }
    timeout.cancel()
  }

  /// Awaits a task's result with a deadline that does not depend on the task finishing: the
  /// first of the result and the deadline wins a one-shot waiter. On expiry it records an
  /// issue, releases every blocked native call and throws `DeadlineExpired`, so a broken
  /// executor makes the test fail, never hang.
  func bounded<T: Sendable, F: Error>(
    _ task: Task<T, F>, deadline: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws -> T {
    let waiter = OneShot<Result<T, any Error>>()
    let watch = Task { waiter.fulfil(await task.result.mapError { $0 as any Error }) }
    let timeout = Task {
      try? await Task.sleep(for: deadline)  // deadline-fallback: bounds the request's own completion
      waiter.fulfil(.failure(DeadlineExpired()))
    }
    let result = await waiter.value()
    watch.cancel()
    timeout.cancel()
    if case .failure(let error) = result, error is DeadlineExpired {
      Issue.record("the task never completed", sourceLocation: sourceLocation)
      releaseEverything()
    }
    return try result.get()
  }

  /// Unblocks every native call, now and later: used only when a deadline expired.
  func releaseEverything() {
    let all = lock.withLock { () -> [FakeSession] in
      _released = true
      return Array(sessions.values)
    }
    for session in all { for _ in 0..<64 { session.gate.signal() } }
    for gate in loadGates.values { for _ in 0..<64 { gate.signal() } }
  }

  private var _released = false
  var releasedAll: Bool { lock.withLock { _released } }

  private func giveUp(_ id: UUID, sourceLocation: SourceLocation) {
    lock.lock()
    let pending = waiters.filter { $0.id == id }
    waiters.removeAll { $0.id == id }
    lock.unlock()
    guard !pending.isEmpty else { return }
    Issue.record("the expected native signal never arrived", sourceLocation: sourceLocation)
    for waiter in pending { waiter.resume.resume() }
    releaseEverything()
  }
}

private final class FakeSession: TranscribeCppEngineSession, @unchecked Sendable {
  let name: String
  unowned let native: FakeNative
  let gate = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var _abort = false
  var abortFlag: Bool { lock.withLock { _abort } }

  init(name: String, native: FakeNative) {
    self.name = name
    self.native = native
  }

  func requestAbort() {
    lock.withLock { _abort = true }
    native.record("abort \(name)")
    // An honouring native call stops at its next poll: wake it.
    if !native.ignoresAbort.contains(name) { gate.signal() }
  }

  func clearAbort() { lock.withLock { _abort = false } }

  func detectLanguage(samples: [Float]) throws -> TranscribeCppLanguageObservation {
    _ = try run(
      samples: samples, language: nil, onProgress: nil, onInferenceEntered: nil, shouldStop: nil)
    return TranscribeCppLanguageObservation(code: "en", logProb: -0.01)
  }

  func run(
    samples: [Float], language: String?, onProgress: ((Int64, Int64) -> Void)?,
    onInferenceEntered: (() -> Void)?, shouldStop: (() -> Bool)?
  ) throws -> TranscribeCppRunResult {
    if shouldStop?() == true { throw FakeAbort() }
    onInferenceEntered?()
    native.enter(self, samples: samples)
    if !native.releasedAll { gate.wait() }
    let aborted = abortFlag && !native.ignoresAbort.contains(name)
    native.exit(self)
    if aborted { throw FakeAbort() }
    return native.results[name]
      ?? TranscribeCppRunResult(text: name, detectedLanguage: nil, segments: [])
  }

  func close() { native.record("close \(name)") }
}

private struct FakeAbort: Error {}

private struct DeadlineExpired: Error {}

/// A value set at most once; `value()` waits for it. The first `fulfil` wins.
private final class OneShot<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value?
  private var waiter: CheckedContinuation<Value, Never>?

  func fulfil(_ value: Value) {
    lock.lock()
    guard stored == nil else {
      lock.unlock()
      return
    }
    stored = value
    let waiting = waiter
    waiter = nil
    lock.unlock()
    waiting?.resume(returning: value)
  }

  func value() async -> Value {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let stored {
        lock.unlock()
        continuation.resume(returning: stored)
      } else {
        waiter = continuation
        lock.unlock()
      }
    }
  }
}

// MARK: - #3735 Chunk 9: the Universal preview yields to the heart

/// The Universal Live Preview's rolling session and runtime over a REAL executor (fake native
/// sessions): live-preview.md RULE: universal-preview-engine-safety invariant 4.
///
/// **What the user sees when this fails:** with the on-screen preview running, the final
/// dictation waits behind a preview decode (slower text after Stop), two models run on the GPU
/// at once, or the pill shows words from a decode the heart interrupted.
@Suite("Universal preview yields to the heart (#3735)", .serialized, .tags(.productOutcome))
struct TranscribeCppPreviewPriorityTests {

  /// Forwards to one test executor, so the runtime's real lane choices reach real scheduling.
  private struct ExecutorDriver: WhisperExecutorDriving {
    typealias Handle = TranscribeCppExecutor.ModelHandle
    let executor: TranscribeCppExecutor
    func load(modelPath: String, lane: TranscribeCppExecutor.Lane) async throws -> Handle {
      try await executor.load(modelPath: modelPath, lane: lane)
    }
    func detectLanguage(_ handle: Handle, samples: [Float], lane: TranscribeCppExecutor.Lane)
      async throws -> TranscribeCppLanguageObservation
    {
      try await executor.detectLanguage(handle, samples: samples, lane: lane)
    }
    func transcribe(
      _ handle: Handle, samples: [Float], language: String?, lane: TranscribeCppExecutor.Lane,
      onInferenceEntered: (@Sendable () -> Void)?, onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> TranscribeCppRunResult {
      try await executor.transcribe(
        handle, samples: samples, language: language, lane: lane, onProgress: onProgress,
        onInferenceEntered: onInferenceEntered)
    }
    func waitForDrain(_ handle: Handle) async { await executor.waitForDrain(handle) }
    func unload(_ handle: Handle) async { await executor.unload(handle) }
  }

  /// Texts the preview publishes, with a signal for the first one.
  private final class Published: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    private var waiter: CheckedContinuation<Void, Never>?
    var all: [String] { lock.withLock { texts } }
    func append(_ text: String) {
      let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        texts.append(text)
        defer { waiter = nil }
        return waiter
      }
      w?.resume()
    }
    func first() async {
      await withCheckedContinuation { c in
        let now = lock.withLock { () -> Bool in
          if !texts.isEmpty { return true }
          waiter = c
          return false
        }
        if now { c.resume() }
      }
    }
  }

  private static let small = "small"
  private static let heard = TranscribeCppRunResult(
    text: "Hello there.", detectedLanguage: nil,
    segments: [TranscribeCppSegment(startMs: 0, endMs: 1_100, text: "Hello there.")])
  /// 1.0 s of tone then 0.2 s of silence (19_200 samples). #3801: the preview's results pass the
  /// silent-tail filter, which needs room quieter than the speech to tell voice from silence;
  /// an unbroken tone would classify its own fake segment as unvoiced.
  private static let speech: [Float] = (0..<19_200).map {
    $0 < 16_000 ? Float(sin(Double($0) * 0.05)) * 0.2 : 0
  }

  private static func runtime(
    _ executor: TranscribeCppExecutor, residency: TranscribeCppPreviewResidency = .init()
  ) -> TranscribeCppPreviewRuntime {
    TranscribeCppPreviewRuntime(
      driver: ExecutorDriver(executor: executor), modelPath: small, isAdmitted: { true },
      cadence: .milliseconds(1), residency: residency)
  }

  /// A bounded wait (the rolling tests' deadline helper: expiry fails the test, never hangs).
  /// Expiry releases every native call, so work the expired step left parked returns (#3808).
  private static func within(
    _ what: String, _ native: FakeNative, sourceLocation: SourceLocation = #_sourceLocation,
    _ ready: @escaping @Sendable () async -> Void
  ) async {
    await TranscribeCppRollingSessionTests.within(
      what, sourceLocation: sourceLocation, onExpiry: { native.releaseEverything() }, ready)
  }

  @Test(
    "a heart request aborts the running preview decode, runs after its native return, and the preview shows nothing from it"
  )
  func heartPreemptsThePreview() async throws {
    let native = FakeNative(results: [Self.small: Self.heard])
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let heart = try await executor.load(modelPath: "turbo", lane: .heart)
    let published = Published()
    let session = try await Self.runtime(executor).makeSession(
      language: "en", hypothesisRetentionLimit: 2_000, onHypothesis: published.append)
    await session.start { (Self.speech, Self.speech.count) }
    await native.waitForArrivals(1)
    #expect(native.log == ["enter small"], "control: the preview decode is inside native code")

    let h = Task {
      try await executor.transcribe(heart, samples: [1], language: "en", lane: .heart)
    }
    await native.waitForAbort(Self.small)
    await native.waitForArrivals(2)
    // The aborted preview run returned BEFORE the heart run entered: never two at once.
    #expect(
      Array(native.log.prefix(4)) == ["enter small", "abort small", "exit small", "enter turbo"])
    #expect(published.all.isEmpty, "a preempted decode must publish nothing")
    native.release("turbo")
    #expect(try await native.bounded(h).text == "turbo")

    // The preview resumes on its next cycle and publishes the retried audio.
    await native.waitForArrivals(3)
    native.release(Self.small)
    await Self.within("the retried decode's text", native) { await published.first() }
    #expect(published.all == ["Hello there."])
    await Self.within("the preview's stop", native) { await session.cancel() }
    #expect(native.peakInside == 1)
  }

  @Test(
    "while heart work runs the preview never enters native code; it decodes once the heart is done")
  func previewRefusedWhileTheHeartRuns() async throws {
    let native = FakeNative(results: [Self.small: Self.heard])
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let heart = try await executor.load(modelPath: "turbo", lane: .heart)
    // Prepared before the heart works, as the app prepares it before recording: a preview LOAD
    // while heart work runs is refused too (`heartBusy`), which is the same rule.
    let runtime = Self.runtime(executor)
    try await runtime.ensureLoaded()
    let h = Task {
      try await executor.transcribe(heart, samples: [1], language: "en", lane: .heart)
    }
    await native.waitForArrivals(1)

    let published = Published()
    let session = try await runtime.makeSession(
      language: nil, hypothesisRetentionLimit: 2_000, onHypothesis: published.append)
    await session.start { (Self.speech, Self.speech.count) }
    let rolling = try #require(session as? TranscribeCppRollingSession)
    // Three refused cycles: the executor answered `heartBusy` without queueing anything.
    await Self.within("three refused cycles", native) { await rolling.cyclesCompleted(reach: 3) }
    #expect(native.log == ["enter turbo"], "no preview decode while the heart works")
    #expect(published.all.isEmpty)

    native.release("turbo")
    _ = try await native.bounded(h)
    await native.waitForArrivals(2)
    native.release(Self.small)
    await Self.within("the first preview text", native) { await published.first() }
    #expect(published.all == ["Hello there."])
    await Self.within("the preview's stop", native) { await session.cancel() }
  }

  @Test("the preview never shows an invented sentence that sits on the trailing silence (#3801)")
  func previewDropsSilentTail() async throws {
    // 1 s of tone, then 1 s of silence; the fake native result adds "Thank you." over the
    // silence, which the native boundary's silent-tail filter removes before publication.
    let audio: [Float] = (0..<32_000).map { $0 < 16_000 ? Float(sin(Double($0) * 0.05)) * 0.2 : 0 }
    let invented = TranscribeCppRunResult(
      text: "Hello there. Thank you.", detectedLanguage: nil,
      segments: [
        TranscribeCppSegment(startMs: 0, endMs: 1_000, text: "Hello there."),
        TranscribeCppSegment(startMs: 1_500, endMs: 2_000, text: "Thank you."),
      ])
    let native = FakeNative(results: [Self.small: invented])
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let published = Published()
    let session = try await Self.runtime(executor).makeSession(
      language: "en", hypothesisRetentionLimit: 2_000, onHypothesis: published.append)
    await session.start { (audio, audio.count) }
    await native.waitForArrivals(1)
    native.release(Self.small)
    await Self.within("the first preview text", native) { await published.first() }
    #expect(published.all.first == "Hello there.")
    await Self.within("the preview's stop", native) { await session.cancel() }
  }

  @Test("stopping the preview aborts its decode and returns only after the native run ended")
  func stopJoinsTheNativeReturn() async throws {
    let native = FakeNative(results: [Self.small: Self.heard])
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let published = Published()
    let session = try await Self.runtime(executor).makeSession(
      language: "en", hypothesisRetentionLimit: 2_000, onHypothesis: published.append)
    await session.start { (Self.speech, Self.speech.count) }
    await native.waitForArrivals(1)
    await Self.within("the preview's stop", native) { await session.cancel() }
    // Cancel returned: the aborted run had already exited native code.
    #expect(native.log == ["enter small", "abort small", "exit small"])
    #expect(native.inside == 0)
    #expect(published.all.isEmpty)
  }

  @Test(
    "the preview model loads on the preview lane, decodes with padding, and is freed once when released"
  )
  func previewLaneLoadAndRelease() async throws {
    let native = FakeNative(results: [Self.small: Self.heard])
    let executor = TranscribeCppExecutor(makeSession: native.makeSession)
    await native.observe(executor)
    let residency = TranscribeCppPreviewResidency()
    var runtime: TranscribeCppPreviewRuntime?
    do {  // `held` ends with this scope, so `runtime` below is the last strong reference
      let held = Self.runtime(executor, residency: residency)
      async let first: Void = held.ensureLoaded()
      async let second: Void = held.ensureLoaded()
      _ = try await (first, second)
      runtime = held
    }
    #expect(residency.loadedCount == 1, "one load, however often and however concurrently asked")
    let published = Published()
    var session: (any WhisperIncrementalSession)? = try await runtime?.makeSession(
      language: "en", hypothesisRetentionLimit: 2_000, onHypothesis: published.append)
    await session?.start { (Self.speech, Self.speech.count) }
    await native.waitForArrivals(1)
    // The window plus 0.5 s of trailing silence, like the heart's decodes.
    #expect(native.samplesSeen.first?.count == Self.speech.count + 8_000)
    native.release(Self.small)
    await Self.within("the first preview text", native) { await published.first() }
    await Self.within("the preview's stop", native) { [session] in
      await session?.cancel()
    }
    runtime = nil
    #expect(native.closeCount(Self.small) == 0, "a session still holds the runtime and its model")

    session = nil
    await Self.within("the released model's free", native) { await residency.waitUntilNoneLoaded() }
    #expect(native.closeCount(Self.small) == 1)
    #expect(residency.loadedCount == 0)
  }
}
