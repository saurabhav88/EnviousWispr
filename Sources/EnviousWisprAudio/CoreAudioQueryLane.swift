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
/// the lane was busy can run once the worker returns, and `Hooks` that report timeouts, late
/// returns and read durations, so a stuck or recovered driver is visible.
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

  /// What the lane reports, injected by the composition root (this module cannot reach the
  /// telemetry or logging services). Every hook runs outside the lane's lock and must not block.
  package struct Hooks: Sendable {
    /// A read's caller gave up: the deadline won. Once per admitted read; never for `.busy`.
    package var timedOut: @Sendable (_ name: String, _ bound: Duration) -> Void
    /// A read whose caller already timed out finally returned: how long it took, and the bound
    /// that read was given.
    package var abandonedReadReturned:
      @Sendable (_ name: String, _ after: Duration, _ bound: Duration) -> Void
    /// Every read that returns, healthy or abandoned, with how long it ran (for DEBUG logging).
    package var completed: @Sendable (_ name: String, _ duration: Duration) -> Void
    /// DEBUG only: an armed stall is about to block this read (`armStallForNextRead`).
    package var debugStallFired: @Sendable (_ name: String, _ stall: Duration) -> Void

    package init(
      timedOut: @escaping @Sendable (String, Duration) -> Void = { _, _ in },
      abandonedReadReturned: @escaping @Sendable (String, Duration, Duration) -> Void = {
        _, _, _ in
      },
      completed: @escaping @Sendable (String, Duration) -> Void = { _, _ in },
      debugStallFired: @escaping @Sendable (String, Duration) -> Void = { _, _ in }
    ) {
      self.timedOut = timedOut
      self.abandonedReadReturned = abandonedReadReturned
      self.completed = completed
      self.debugStallFired = debugStallFired
    }
  }

  private struct State {
    var busy = false
    var availabilityWaiters: [@Sendable () -> Void] = []
  }

  private let queue: DispatchQueue
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let scheduleDeadline: @Sendable (Duration, @escaping @Sendable () -> Void) -> Void
  private let now: @Sendable () -> ContinuousClock.Instant
  private let hooks: Hooks
  #if DEBUG
    /// A one-shot stall for the next admitted read (UAT seam, `force_core_audio_stall`).
    private let stallArm = OSAllocatedUnfairLock<Duration?>(initialState: nil)
    private let stallExecutor: @Sendable (Duration) -> Void
  #endif

  package convenience init(label: String = "com.enviouswispr.coreaudio.query", hooks: Hooks = Hooks()) {
    self.init(
      label: label,
      scheduleDeadline: { bound, fire in
        // A timer, not a task: it fires even when every worker thread is busy.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
          deadline: .now() + Self.seconds(bound), execute: fire)
      },
      now: { ContinuousClock.now },
      hooks: hooks)
  }

  /// Test seam: the deadline scheduler and clock are injectable so tests fire the deadline
  /// themselves instead of waiting for time to pass; `stallExecutor` (DEBUG) lets a test gate
  /// an armed stall instead of sleeping.
  package init(
    label: String,
    scheduleDeadline: @escaping @Sendable (Duration, @escaping @Sendable () -> Void) -> Void,
    now: @escaping @Sendable () -> ContinuousClock.Instant,
    hooks: Hooks = Hooks(),
    stallExecutor: @escaping @Sendable (Duration) -> Void = { stall in
      Thread.sleep(
        forTimeInterval: Double(stall.components.seconds) + Double(stall.components.attoseconds) / 1e18)
    }
  ) {
    self.queue = DispatchQueue(label: label, qos: .userInitiated)
    self.scheduleDeadline = scheduleDeadline
    self.now = now
    self.hooks = hooks
    #if DEBUG
      self.stallExecutor = stallExecutor
    #endif
  }

  #if DEBUG
    /// UAT seam (DEBUG only, logged through `Hooks.debugStallFired`): the next admitted read
    /// blocks for `stall` on the lane's own queue before running, which is exactly what a caller
    /// sees when a driver stops answering. A busy refusal does not consume it.
    package func armStallForNextRead(_ stall: Duration) {
      stallArm.withLock { $0 = stall }
    }

    /// Takes and clears the arm in one step, so a re-arm made while an older stall runs is kept.
    private func takeStallArm() -> Duration? {
      stallArm.withLock { arm -> Duration? in
        defer { arm = nil }
        return arm
      }
    }
  #endif

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
    let hooks = hooks
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
        #if DEBUG
          if let stall = takeStallArm() {
            hooks.debugStallFired(name, stall)
            stallExecutor(stall)
          }
        #endif
        let value = read()
        let elapsed = now() - started
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
          hooks.abandonedReadReturned(name, elapsed, bound)
        }
        hooks.completed(name, elapsed)
        for waiter in waiters { waiter() }
      }
      scheduleDeadline(bound) {
        if claimResume() {
          continuation.resume(returning: .timedOut)
          hooks.timedOut(name, bound)
        }
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
