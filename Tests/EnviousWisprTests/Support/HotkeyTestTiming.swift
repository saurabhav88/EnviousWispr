import EnviousWisprServices
import Foundation
import os

/// #3544: the record-key gesture engine reads its clock and schedules its lone-tap wait off the
/// main actor, so the hotkey suites' clock and timer must be safe to touch from any thread. Both
/// are driven ONLY by the test: time moves when a test sets it, and a wait ends when a test fires
/// it. Nothing here reads a real clock or sleeps.
final class HotkeyTestClock: Sendable {
  private let value: OSAllocatedUnfairLock<TimeInterval>

  init(_ start: TimeInterval) { value = OSAllocatedUnfairLock(initialState: start) }

  var now: TimeInterval {
    get { value.withLock { $0 } }
    set { value.withLock { $0 = newValue } }
  }

  func advance(ms: Int) { value.withLock { $0 += Double(ms) / 1000.0 } }

  /// The `uptime:` seam.
  var uptime: @Sendable () -> TimeInterval { { [self] in now } }
}

/// The engine's one-shot `scheduler:` seam, fired by hand. A request records the deadline it
/// will end at (the clock's `now` plus the delay asked for); `fireDue()` runs every request whose
/// deadline has passed, on the calling thread, outside its own lock.
final class HotkeyTestScheduler: Sendable {
  private struct Entry: Sendable {
    let deadline: TimeInterval
    let fire: @Sendable () -> Void
  }
  private struct State: Sendable {
    var pending: [Int: Entry] = [:]
    var nextID = 0
    var requestedDelays: [TimeInterval] = []
    var requestedDeadlines: [TimeInterval] = []
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let clock: HotkeyTestClock

  init(clock: HotkeyTestClock) { self.clock = clock }

  var requestedDelays: [TimeInterval] { state.withLock { $0.requestedDelays } }
  var requestedDeadlines: [TimeInterval] { state.withLock { $0.requestedDeadlines } }
  var pendingCount: Int { state.withLock { $0.pending.count } }

  var scheduler: RecordGestureEngine.Scheduler {
    { [self] delay, fire in
      let deadline = clock.now + delay
      let id = state.withLock { s -> Int in
        let id = s.nextID
        s.nextID += 1
        s.pending[id] = Entry(deadline: deadline, fire: fire)
        s.requestedDelays.append(delay)
        s.requestedDeadlines.append(deadline)
        return id
      }
      return RecordGestureEngine.TimerHandle(cancel: { [self] in
        _ = state.withLock { $0.pending.removeValue(forKey: id) }
      })
    }
  }

  /// Fire every pending request whose deadline is at or before `clock.now`.
  func fireDue() {
    let now = clock.now
    let due = state.withLock { s -> [Entry] in
      let ids = s.pending.filter { $0.value.deadline <= now + 1e-9 }.map(\.key).sorted()
      return ids.compactMap { s.pending.removeValue(forKey: $0) }
    }
    for entry in due { entry.fire() }
  }
}
