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
