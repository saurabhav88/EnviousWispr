import Foundation
import Testing

/// Waits that fail a test instead of hanging the lane (#3735 chunk 7).
///
/// Each wait races the awaited thing against a deadline in a one-shot that the FIRST of the two
/// fulfils; the waiter never joins the stalled work, so an awaited signal or task that never
/// arrives costs the deadline and then a recorded issue. The deadline is a hang guard, not a
/// settle budget: on a healthy run the signal or task wins.
enum BoundedWait {
  struct Expired: Error {}

  /// A signal that something happened. `fire()` may run on any thread, more than once.
  final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    func fire() {
      let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        fired = true
        defer { waiters = [] }
        return waiters
      }
      for waiter in ready { waiter.resume() }
    }

    var hasFired: Bool { lock.withLock { fired } }

    fileprivate func wait() async {
      await withCheckedContinuation { continuation in
        let now = lock.withLock { () -> Bool in
          if fired { return true }
          waiters.append(continuation)
          return false
        }
        if now { continuation.resume() }
      }
    }
  }

  /// Returns once `signal` fires; throws `Expired` (and records an issue) after `deadline`.
  static func until(
    _ signal: Signal, deadline: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let outcome = OneShot<Bool>()
    let watch = Task {
      await signal.wait()
      outcome.fulfil(true)
    }
    let timer = Task {
      try? await Task.sleep(for: deadline)  // deadline-fallback: hang guard, not a settle budget
      outcome.fulfil(false)
    }
    let arrived = await outcome.value()
    watch.cancel()
    timer.cancel()
    guard arrived else {
      Issue.record("the awaited signal never fired", sourceLocation: sourceLocation)
      throw Expired()
    }
  }

  /// A task's result, or `Expired` (and a recorded issue) after `deadline`. On expiry the task is
  /// cancelled and `onExpiry` runs, to release whatever gate the task may be blocked on.
  static func result<T: Sendable, F: Error>(
    of task: Task<T, F>, deadline: Duration = .seconds(30),
    onExpiry: @Sendable () -> Void = {},
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws -> Result<T, F> {
    let outcome = OneShot<Result<T, F>?>()
    let watch = Task { outcome.fulfil(await task.result) }
    let timer = Task {
      try? await Task.sleep(for: deadline)  // deadline-fallback: hang guard, not a settle budget
      outcome.fulfil(nil)
    }
    let result = await outcome.value()
    watch.cancel()
    timer.cancel()
    guard let result else {
      Issue.record("the awaited task never completed", sourceLocation: sourceLocation)
      task.cancel()
      onExpiry()
      throw Expired()
    }
    return result
  }

  /// A value set at most once; `value()` waits for it. The first `fulfil` wins.
  private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    private var isSet = false
    private var waiter: CheckedContinuation<Value, Never>?

    func fulfil(_ value: Value) {
      let waiting = lock.withLock { () -> CheckedContinuation<Value, Never>? in
        guard !isSet else { return nil }
        isSet = true
        stored = value
        defer { waiter = nil }
        return waiter
      }
      waiting?.resume(returning: value)
    }

    func value() async -> Value {
      await withCheckedContinuation { continuation in
        let ready = lock.withLock { () -> Value? in
          if isSet { return stored }
          waiter = continuation
          return nil
        }
        if let ready { continuation.resume(returning: ready) }
      }
    }
  }
}

/// The deadline itself works: a signal nobody fires and a task that never finishes both fail
/// within their deadline instead of hanging.
@Suite("Bounded waits fail instead of hanging (#3735)", .tags(.harnessContract))
struct BoundedWaitTests {
  @Test("a signal that never fires expires")
  func silentSignalExpires() async {
    await withKnownIssue("the signal is never fired, so the wait must expire") {
      await #expect(throws: BoundedWait.Expired.self) {
        try await BoundedWait.until(BoundedWait.Signal(), deadline: .milliseconds(200))
      }
    }
  }

  @Test("a task that never finishes expires, and its gate is released")
  func stalledTaskExpires() async {
    let released = BoundedWait.Signal()
    let never = Task<Int, Never> {
      try? await Task.sleep(for: .seconds(600))  // deadline-fallback: a subject that never finishes
      return 1
    }
    await withKnownIssue("the task never finishes, so the wait must expire") {
      await #expect(throws: BoundedWait.Expired.self) {
        _ = try await BoundedWait.result(
          of: never, deadline: .milliseconds(200), onExpiry: { released.fire() })
      }
    }
    #expect(released.hasFired)
    #expect(never.isCancelled)
  }

  @Test("a fired signal and a finished task return at once")
  func arrivalsWin() async throws {
    let signal = BoundedWait.Signal()
    signal.fire()
    try await BoundedWait.until(signal, deadline: .seconds(5))
    let done = Task { 7 }
    #expect(try await BoundedWait.result(of: done, deadline: .seconds(5)).get() == 7)
  }
}
