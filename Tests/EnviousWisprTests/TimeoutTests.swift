import Foundation
import Testing

@testable import EnviousWisprCore

@Suite("Timeout")
struct TimeoutTests {

  @Test("Returns completed when work finishes before deadline")
  func completesBeforeDeadline() async {
    let outcome = await raceWithTimeout(milliseconds: 1_000) {
      try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
      return 42
    }
    switch outcome {
    case .completed(let value): #expect(value == 42)
    case .timedOut: Issue.record("expected .completed, got .timedOut")
    case .threw(let e): Issue.record("expected .completed, got .threw(\(e))")
    }
  }

  @Test("Returns timedOut when deadline expires before work completes")
  func timesOutWhenWorkSlow() async {
    let start = ContinuousClock.now
    let outcome = await raceWithTimeout(milliseconds: 100) {
      // Cancellation-aware sleep so the work observes cancel and returns.
      try await Task.sleep(nanoseconds: 10_000_000_000)  // 10s, well past deadline
      return "should not return"
    }
    let elapsed = ContinuousClock.now - start
    switch outcome {
    case .timedOut:
      let (s, a) = elapsed.components
      // a is attoseconds (1e-18), convert to ms by dividing by 1e15
      let ms = Int(s) * 1_000 + Int(a / 1_000_000_000_000_000)
      #expect(ms < 1_000, "timeout fired at ~100ms, observed \(ms)ms")
    case .completed: Issue.record("expected .timedOut, got .completed")
    case .threw(let e): Issue.record("expected .timedOut, got .threw(\(e))")
    }
  }

  @Test("Returns threw when work throws before deadline")
  func surfacesError() async {
    struct SentinelError: Error, Equatable {}
    let outcome = await raceWithTimeout(milliseconds: 1_000) {
      try await Task.sleep(nanoseconds: 50_000_000)
      throw SentinelError()
    }
    switch outcome {
    case .threw(let e): #expect(e is SentinelError)
    case .completed: Issue.record("expected .threw, got .completed")
    case .timedOut: Issue.record("expected .threw, got .timedOut")
    }
  }

  @Test("Caller cancellation surfaces as CancellationError, not timedOut")
  func callerCancellationSurfacesAsThrew() async {
    // Spawn a task that calls raceWithTimeout with a long deadline, then
    // cancel that task. The race should return .threw(CancellationError())
    // instead of .timedOut.
    let task = Task<TimeoutOutcome<Int>, Never> {
      await raceWithTimeout(milliseconds: 60_000) {
        try await Task.sleep(nanoseconds: 10_000_000_000)  // 10s, well past
        return 1
      }
    }
    // Give the race a moment to enter its wait, then cancel the parent.
    try? await Task.sleep(nanoseconds: 50_000_000)
    task.cancel()
    let outcome = await task.value
    switch outcome {
    case .threw(let e): #expect(e is CancellationError)
    case .completed: Issue.record("expected .threw, got .completed")
    case .timedOut: Issue.record("expected .threw(CancellationError), got .timedOut")
    }
  }

  @Test("Wedged work that ignores cancellation does not pin the caller")
  func wedgedWorkDoesNotPinCaller() async {
    // Simulate a non-cooperative wedge: a busy loop that ignores cancellation
    // for a bounded duration. raceWithTimeout must still return at the
    // deadline; the wedged work runs to completion in the background.
    let start = ContinuousClock.now
    let outcome = await raceWithTimeout(milliseconds: 100) {
      // Non-cancellation-aware busy wait. Bounded so the test eventually
      // releases the detached task.
      let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
      while ContinuousClock.now < deadline {
        // Tight loop; do not call any cancellation checkpoint.
      }
      return "wedged work returned eventually"
    }
    let elapsed = ContinuousClock.now - start
    let (s, a) = elapsed.components
    let ms = Int(s) * 1_000 + Int(a / 1_000_000_000_000_000)
    switch outcome {
    case .timedOut:
      // Caller must return at ~deadline (100ms), well before the wedge
      // finishes (500ms). Allow generous slack for CI.
      #expect(
        ms < 400, "raceWithTimeout returned in \(ms)ms; wedge would have pinned caller to ~500ms")
    case .completed: Issue.record("expected .timedOut, got .completed")
    case .threw(let e): Issue.record("expected .timedOut, got .threw(\(e))")
    }
  }

  @Test("Timeout cancels the work task (cancellation-aware work observes cancel)")
  func cancelsWorkOnTimeout() async {
    actor Flag {
      var cancelled = false
      func mark() { cancelled = true }
    }
    let flag = Flag()
    _ = await raceWithTimeout(milliseconds: 50) {
      do {
        try await Task.sleep(nanoseconds: 5_000_000_000)
      } catch is CancellationError {
        await flag.mark()
      } catch {
        // Other thrown errors also count as observation
        await flag.mark()
      }
      return ()
    }
    // Give the work a tick to observe cancel and run its catch
    try? await Task.sleep(nanoseconds: 100_000_000)
    let observed = await flag.cancelled
    #expect(observed, "work should observe cancellation when timeout fires")
  }
}
