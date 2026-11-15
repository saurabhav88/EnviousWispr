import Foundation
import os

/// One Core Audio read at a time, off the main actor and bounded (#4021).
///
/// A third-party audio driver can stop answering a HAL property read: the call then blocks
/// inside `mach_msg` with no timeout and no way to cancel it (captured twice on the dev Mac,
/// main thread stuck in `AudioDeviceList.refresh()` -> `AudioObjectGetPropertyData`; same class
/// as JUCE #1686, Firefox bug 2045209, OBS #13902). Asking from the main actor froze the app.
///
/// Port of `CallEvidenceRead.Lane` (#4012 §3.3), whose contract this keeps whole:
/// - Reads run on this lane's own serial queue, never the shared Swift worker pool.
/// - The caller waits at most `bound`; a read that does not finish in time is abandoned.
/// - Only one read runs at a time: while an abandoned read is stuck, later reads answer
///   `.busy` at once without piling up behind it. Busy clears only when the worker actually
///   returns, never because a caller gave up, so one stuck read is contained, not multiplied.
/// - The deadline is a dispatch timer, not a task: it fires even when every worker thread is
///   busy and does not depend on the main actor (why `withOffActorOrderedDeadline`, whose timer
///   runs on the cooperative pool, is not used here).
///
/// Added for #4021: an availability notification (`whenAvailable`), so a refresh refused while
/// the lane was busy can run once the worker returns, and a report when an abandoned read
/// finally returns, so a recovered driver is visible.
///
/// Callers must not hold an app lock while a read runs; the lane takes and releases its own
/// lock before and after the read, never across it.
package final class CoreAudioQueryLane: Sendable {
  /// What a bounded read produced. `.timedOut` and `.busy` mean "no answer", never "nothing".
  package enum Outcome<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
    case busy
  }

  private struct State {
    var busy = false
    var availabilityWaiters: [@Sendable () -> Void] = []
  }

  private let queue: DispatchQueue
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let scheduleDeadline: @Sendable (Duration, @escaping @Sendable () -> Void) -> Void
  private let now: @Sendable () -> ContinuousClock.Instant
  private let onAbandonedReadReturned: @Sendable (_ name: String, _ after: Duration) -> Void

  /// - Parameter onAbandonedReadReturned: called on the lane's queue when a read whose caller
  ///   already timed out finally returns, with the time since the read started.
  package convenience init(
    label: String = "com.enviouswispr.coreaudio.query",
    onAbandonedReadReturned: @escaping @Sendable (_ name: String, _ after: Duration) -> Void = {
      _, _ in
    }
  ) {
    self.init(
      label: label,
      scheduleDeadline: { bound, fire in
        // A timer, not a task: it fires even when every worker thread is busy.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
          deadline: .now() + Self.seconds(bound), execute: fire)
      },
      now: { ContinuousClock.now },
      onAbandonedReadReturned: onAbandonedReadReturned)
  }

  /// Test seam: the deadline scheduler and clock are injectable so tests fire the deadline
  /// themselves instead of waiting for time to pass.
  package init(
    label: String,
    scheduleDeadline: @escaping @Sendable (Duration, @escaping @Sendable () -> Void) -> Void,
    now: @escaping @Sendable () -> ContinuousClock.Instant,
    onAbandonedReadReturned: @escaping @Sendable (_ name: String, _ after: Duration) -> Void
  ) {
    self.queue = DispatchQueue(label: label, qos: .userInitiated)
    self.scheduleDeadline = scheduleDeadline
    self.now = now
    self.onAbandonedReadReturned = onAbandonedReadReturned
  }

  /// Runs `read` on the lane and waits at most `bound` for it.
  ///
  /// Default bound 1 s: the shipped precedent for an abandoned off-main OS read
  /// (`CallEvidenceRead.boundedSnapshot`). It defines "slow", not proven "stuck"; the caller
  /// never blocks the main actor either way.
  package func bounded<Value: Sendable>(
    _ name: String, bound: Duration = .seconds(1), _ read: @escaping @Sendable () -> Value
  ) async -> Outcome<Value> {
    let claimed = state.withLock { state -> Bool in
      if state.busy { return false }
      state.busy = true
      return true
    }
    guard claimed else { return .busy }
    let started = now()
    return await withCheckedContinuation {
      (continuation: CheckedContinuation<Outcome<Value>, Never>) in
      let resumed = OSAllocatedUnfairLock(initialState: false)
      let claimResume: @Sendable () -> Bool = {
        resumed.withLock { done -> Bool in
          if done { return false }
          done = true
          return true
        }
      }
      queue.async { [self] in
        let value = read()
        // Busy clears on actual worker completion, and waiters are taken in the same lock
        // scope, so a waiter added after this point sees `busy == false` and runs at once.
        let waiters = state.withLock { state -> [@Sendable () -> Void] in
          state.busy = false
          let waiters = state.availabilityWaiters
          state.availabilityWaiters = []
          return waiters
        }
        if claimResume() {
          continuation.resume(returning: .value(value))
        } else {
          onAbandonedReadReturned(name, now() - started)
        }
        for waiter in waiters { waiter() }
      }
      scheduleDeadline(bound) {
        if claimResume() { continuation.resume(returning: .timedOut) }
      }
    }
  }

  /// Calls `callback` once the lane has no read in flight: at once (on the calling thread) when
  /// it is free now, otherwise on the lane's queue right after the running read returns.
  /// Level-triggered, so subscribing after a read already finished never loses the wake-up.
  package func whenAvailable(_ callback: @escaping @Sendable () -> Void) {
    let runNow = state.withLock { state -> Bool in
      if state.busy {
        state.availabilityWaiters.append(callback)
        return false
      }
      return true
    }
    if runNow { callback() }
  }

  /// Whether a read is in flight (including an abandoned one). For tests and diagnostics.
  package var isBusy: Bool { state.withLock { $0.busy } }

  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}
