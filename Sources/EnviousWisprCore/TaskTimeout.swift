import Foundation
import os

/// Thrown when a `withThrowingTimeout` call exceeds its deadline.
public struct TimeoutError: Error, CustomStringConvertible {
  public let seconds: Double
  public var description: String { "Task timed out after \(seconds)s" }

  public init(seconds: Double) {
    self.seconds = seconds
  }
}

// MARK: - Sentry identity

/// Pins the Sentry grouping key to the exact string this type has been
/// sending in production (#1525 PR H), mirroring `HeartPathError`'s shipped
/// pattern (#1524). One shape today, reused at two capture sites
/// (`InverseTextNormalizationStep`'s ITN timeout, `TextProcessingRunner`'s
/// polish timeout) — a struct, so no reorder risk exists yet, but this closes
/// the latent risk before a second shape is ever added and preserves the live
/// production issue (ENVIOUSWISPR-32, `polish_provider_failed:
/// EnviousWisprCore.TimeoutError#1`) cross-checked before pinning.
extension TimeoutError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String { "EnviousWisprCore.TimeoutError#1" }
  public var sentrySemanticID: String { "core.timeout" }
}

/// Run an async operation with a timeout. If the operation doesn't complete
/// within `seconds`, the child task is cancelled and `TimeoutError` is thrown.
public func withThrowingTimeout<T: Sendable>(
  seconds: Double,
  operation: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await Task.sleep(for: .seconds(seconds))
      throw TimeoutError(seconds: seconds)
    }
    // First to complete wins — the other is cancelled.
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}

/// Run `operation` with a TRUE wall-clock deadline: returns its result if it
/// finishes within `seconds`, otherwise `nil` once the deadline passes —
/// WITHOUT awaiting the operation after timing out. Unlike `withThrowingTimeout`
/// (whose task-group scope awaits the losing child), this abandons a losing
/// operation, so a SYNCHRONOUS, non-cooperative blocking call (e.g. Core ML
/// `MLModel.prediction`) cannot make the caller wait past the deadline. The
/// abandoned operation finishes in the background and its result is discarded.
/// Use for fail-open LIMB budgets where bounding the caller matters more than
/// the operation's completion. (#832/#913 PR8 — Codex P1.)
public func withDeadline<T: Sendable>(
  seconds: Double,
  operation: @escaping @Sendable () async -> T
) async -> T? {
  let resumed = OSAllocatedUnfairLock(initialState: false)
  func claim() -> Bool {
    resumed.withLock { done in
      done
        ? false
        : {
          done = true
          return true
        }()
    }
  }
  return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
    let operationTask = Task(priority: .userInitiated) {
      let value = await operation()
      if claim() { continuation.resume(returning: value) }
    }
    Task {
      try? await Task.sleep(for: .seconds(seconds))
      if claim() {
        operationTask.cancel()  // best-effort; cannot preempt a blocked thread
        continuation.resume(returning: nil)
      }
    }
  }
}

/// Run `operation` with a deadline whose timer is scheduled ON THE MAIN ACTOR,
/// guaranteeing `onTimeout` runs to completion BEFORE the caller is resumed on
/// timeout — the ordering `withDeadline` does not provide (it resumes the
/// caller immediately once the deadline claims, with no hook to run cleanup
/// first). Use this instead of `withDeadline` whenever a timeout must actively
/// supersede/cancel a resource the operation was mutating, so a later caller
/// (e.g. a fresh session) can never race an abandoned operation's late cleanup,
/// AND that cleanup genuinely needs the main actor.
///
/// Both arming the timer and handling its wake require main-actor
/// availability. While the main actor is blocked, this timer cannot claim a
/// timeout; an operation completing during that interval can still win.
/// Measured 2026-09-08 under a 1.2 s main-actor block: 0 of 8 trials timed out
/// and the caller waited 1466.9 ms against a 100 ms budget
/// (`docs/feature-requests/issue-1946-artifacts/2026-09-08-which-primitives-are-defective.out`).
/// This intentionally does not provide an actor-independent elapsed-time
/// cutoff. When the timeout handler does NOT need the main actor, use
/// `withOffActorOrderedDeadline`, whose timer runs on the cooperative pool.
///
/// `onTimeout` MUST be synchronous, non-throwing, and MUST NOT suspend — an
/// async cleanup hook would either leave this call's own wait unbounded, or
/// need its own inner deadline, which would just recreate the exact same
/// ordering race one layer down. If the real cleanup needs to await
/// something, that something must itself already be synchronous
/// (fire-and-forget with its own internal bookkeeping) — do not widen this
/// contract to admit an async closure. (#1707 — Codex grounded review r3/r4.)
///
/// On success (operation wins the race), `onTimeout` is never called.
public func withMainActorOrderedDeadline<T: Sendable>(
  seconds: Double,
  operation: @escaping @Sendable () async -> T,
  onTimeout: @escaping @Sendable @MainActor () -> Void
) async -> T? {
  let resumed = OSAllocatedUnfairLock(initialState: false)
  func claim() -> Bool {
    resumed.withLock { done in
      done
        ? false
        : {
          done = true
          return true
        }()
    }
  }
  return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
    let operationTask = Task(priority: .userInitiated) {
      let value = await operation()
      if claim() { continuation.resume(returning: value) }
    }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(seconds))
      if claim() {
        operationTask.cancel()  // best-effort; cannot preempt a blocked thread
        onTimeout()  // synchronous — completes before the resume below
        continuation.resume(returning: nil)
      }
    }
  }
}

/// The sibling of `withMainActorOrderedDeadline` for timeout handlers that do
/// NOT need the main actor. It keeps the #1707 ordering property — `onTimeout`
/// runs to completion before the caller is resumed — and differs in exactly one
/// respect: the deadline is an absolute instant on the continuous clock taken
/// at ENTRY, and the timer that waits for it runs on the cooperative pool. A
/// blocked main actor therefore cannot postpone the timeout DECISION. Measured
/// 2026-09-08 under the same 1.2 s block, a pool timer fired 8 of 8 and bounded
/// its own wait at 104.5 ms against a 100 ms budget
/// (`docs/feature-requests/issue-1946-artifacts/2026-09-08-which-primitives-are-defective.out`).
///
/// `onTimeout` MUST be synchronous, non-throwing, MUST NOT suspend, and must be
/// callable from any executor — the same contract as the main-actor sibling and
/// for the same reason: widening it to an async closure would leave this call's
/// own wait unbounded, or need its own inner deadline, recreating the ordering
/// race one layer down. A handler that touches `@MainActor` state cannot be
/// passed here; the compiler refuses it, which is why these are two names and
/// not one name with a comment.
///
/// What this does NOT do: it does not bound the CALLER's return when the caller
/// itself needs the main actor to continue after the resume. Timer execution
/// still depends on cooperative-pool availability, so this is a FIRST-CLAIM
/// RACE rather than a guaranteed elapsed-time cutoff — an operation returning
/// after the deadline can still win when the timer has not yet run. What it
/// removes is the timer's dependence on one specific, routinely blocked
/// executor. (#1946.)
///
/// On success (operation wins the race), `onTimeout` is never called.
public func withOffActorOrderedDeadline<T: Sendable>(
  seconds: Double,
  operation: @escaping @Sendable () async -> T,
  onTimeout: @escaping @Sendable () -> Void
) async -> T? {
  // Taken here, not inside the timer task, so scheduling delay before the timer
  // first runs is spent against the budget rather than added to it.
  let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
  let resumed = OSAllocatedUnfairLock(initialState: false)
  func claim() -> Bool {
    resumed.withLock { done in
      done
        ? false
        : {
          done = true
          return true
        }()
    }
  }
  return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
    let operationTask = Task(priority: .userInitiated) {
      let value = await operation()
      if claim() { continuation.resume(returning: value) }
    }
    Task {
      try? await Task.sleep(until: deadline, clock: .continuous)
      if claim() {
        operationTask.cancel()  // best-effort; cannot preempt a blocked thread
        onTimeout()  // synchronous — completes before the resume below
        continuation.resume(returning: nil)
      }
    }
  }
}
