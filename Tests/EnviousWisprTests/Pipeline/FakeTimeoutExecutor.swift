import EnviousWisprCore
import Foundation

@testable import EnviousWisprPipeline

/// Deterministic `TextProcessingRunner.TimeoutExecutor` (#784, 2026-05-18).
///
/// The runner calls its executor once per enabled step. A fake that always
/// throws would time out the first normal-budget step before reaching the
/// intended slow step in multi-step tests. So this fake discriminates by
/// budget: throws `TimeoutError(seconds:)` for budgets STRICTLY BELOW
/// `throwBelowSeconds`, runs the operation otherwise. Threshold is required
/// at init (no default) so each test makes the discriminator explicit.
///
/// #794 (2026-05-19): extracted from `TextProcessingRunnerTests` to a shared
/// file so `HeartPathIntegrationTests` can inject the same deterministic
/// executor. Runner tests construct it with `throwBelowSeconds: 0.0` (never
/// throws — every step runs) unless the test is specifically about timeout
/// behavior, in which case `0.1` discriminates the 50ms slow-step budget
/// from the 5s default budget.
@MainActor
final class FakeTimeoutExecutor {
  let throwBelowSeconds: Double

  private(set) var callCount: Int = 0
  private(set) var capturedBudgets: [Double] = []

  init(throwBelowSeconds: Double) {
    self.throwBelowSeconds = throwBelowSeconds
  }

  func run(
    _ seconds: Double,
    _ op: @escaping @MainActor () async throws -> TextProcessingContext
  ) async throws -> TextProcessingContext {
    callCount += 1
    capturedBudgets.append(seconds)
    if seconds < throwBelowSeconds {
      // Yield once before throwing so the fake mirrors the real
      // `withThrowingTimeout`'s yielding behavior (production always
      // suspends inside its task-group `Task.sleep` deadline). Without
      // this yield, the runner returns to the test without giving its
      // prior fire-and-forget logger Tasks a chance to run; under
      // full-suite MainActor saturation, those Tasks can fail to drain.
      await Task.yield()
      throw TimeoutError(seconds: seconds)
    }
    return try await op()
  }
}
