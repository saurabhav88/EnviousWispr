import Foundation

/// Outcome of `raceWithTimeout`. Three terminal cases the caller must handle.
public enum TimeoutOutcome<T: Sendable>: Sendable {
  /// Work returned a value before the deadline.
  case completed(T)
  /// Deadline expired before work returned. The work task was cancelled
  /// cooperatively. Note: Swift cancellation is cooperative — non-cooperative
  /// work (XPC blocking calls, CoreML `MLModel.load`) continues in the
  /// background. The function returns regardless; the caller's state machine
  /// must reset cleanly without depending on the work actually stopping.
  case timedOut
  /// Work threw before the deadline, OR the parent task that called
  /// `raceWithTimeout` was cancelled. Caller cancellation surfaces as
  /// `CancellationError`.
  case threw(Error)
}

/// At-most-once outcome delivery. First sender wins; subsequent senders are
/// dropped. The waiter receives whichever outcome was registered first.
private actor OutcomeBox<T: Sendable> {
  private var outcome: TimeoutOutcome<T>?
  private var waiter: CheckedContinuation<TimeoutOutcome<T>, Never>?

  func deliver(_ value: TimeoutOutcome<T>) {
    guard outcome == nil else { return }
    outcome = value
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: value)
    }
  }

  func wait() async -> TimeoutOutcome<T> {
    if let outcome { return outcome }
    return await withCheckedContinuation { cont in
      waiter = cont
    }
  }
}

/// Race an async operation against a wall-clock deadline.
///
/// The work runs on a detached task so a non-cooperative wedge (XPC stuck,
/// `MLModel.load` stuck) cannot pin the parent's structured concurrency scope.
/// `raceWithTimeout` returns as soon as the deadline expires or the work
/// completes, whichever fires first. Wedged work continues to run in the
/// background until it eventually returns; its result is discarded.
///
/// On timeout, the work task is `cancel()`ed (best-effort, cooperative).
///
/// On parent-task cancellation, the function returns `.threw(CancellationError())`
/// — NOT `.timedOut`. Callers that distinguish "user cancelled" from "deadline
/// fired" must check for `CancellationError` in the `.threw` arm.
///
/// Used for issue #445 model-load watchdog: wraps `try await loadTask.value`
/// (Parakeet) and `try await backend.prepare()` (WhisperKit) so a wedged
/// model load cannot leave the pipeline state machine stuck indefinitely.
public func raceWithTimeout<T: Sendable>(
  milliseconds deadline: UInt64,
  _ work: @Sendable @escaping () async throws -> T
) async -> TimeoutOutcome<T> {
  let box = OutcomeBox<T>()

  // Detached so a wedged `work` cannot block the parent's structured scope.
  let workTask = Task.detached {
    do {
      let value = try await work()
      await box.deliver(.completed(value))
    } catch {
      await box.deliver(.threw(error))
    }
  }

  // Detached so the deadline cannot be co-cancelled by the parent and
  // mistakenly surface as `.timedOut`. Parent cancellation flows via
  // `withTaskCancellationHandler` instead.
  let deadlineTask = Task.detached {
    do {
      try await Task.sleep(nanoseconds: deadline * 1_000_000)
      await box.deliver(.timedOut)
    } catch {
      // Cancelled by us when the work or caller wins first; nothing to do.
    }
  }

  return await withTaskCancellationHandler {
    let result = await box.wait()
    deadlineTask.cancel()
    if case .timedOut = result {
      workTask.cancel()
    }
    return result
  } onCancel: {
    // Parent cancellation: surface as CancellationError, not as a timeout.
    // The work task's eventual completion is dropped because the box has
    // already delivered.
    Task { await box.deliver(.threw(CancellationError())) }
    workTask.cancel()
    deadlineTask.cancel()
  }
}
