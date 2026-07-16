import CoreML
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #1452: `OutputClassifierHolder`'s process-lifetime state machine. Proves the
/// actual acceptance criterion — at most one terminal `.failedNoRetry`/
/// `.failedAfterFallback` per process per disablement, concurrent triggers
/// coalesce onto one load, a non-classifier-fault error (cancellation /
/// unmapped) stays retryable, and #1226's bounded `.cpuAndGPU` retry fires ONLY
/// for `fixtureSelfTestFailed` — without touching CoreML, Sentry, or PostHog
/// at all (the loader is a fake closure injected via `beginLoadIfNeeded`).
@MainActor
@Suite("OutputClassifierHolder state machine")
struct OutputClassifierHolderStateTests {

  /// A trivial `OutputClassifierProtocol` for the `.succeeded` path — never
  /// scored in these tests, only used to prove `.classifier` becomes non-nil.
  private struct StubClassifier: OutputClassifierProtocol {
    var usedFallbackCompute: Bool = false
    func score(input: String, polished: String) async throws -> Double { 0 }
  }

  /// Counts loader invocations across concurrent/sequential calls.
  private actor CallSpy {
    private(set) var count = 0
    func recordCall() { count += 1 }
  }

  /// Gate a parked loader awaits; the test releases it after observing the
  /// loader has actually started (signal-based, no `Task.sleep` — mirrors
  /// `LLMPolishReentrancyTests.ReleaseGate`).
  private actor ReleaseGate {
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func release() {
      released = true
      waiter?.resume()
      waiter = nil
    }
    func wait() async {
      if released { return }
      await withCheckedContinuation { waiter = $0 }
    }
  }

  @Test("successful load: succeeded, classifier becomes non-nil")
  func successfulLoad() async throws {
    let holder = OutputClassifierHolder()
    let spy = CallSpy()
    let outcome = await holder.beginLoadIfNeeded { _ in
      await spy.recordCall()
      return StubClassifier()
    }
    #expect(outcome == .succeeded)
    #expect(holder.classifier != nil)
    #expect(await spy.count == 1)
  }

  @Test(
    "typed OutputClassifierError, non-retry-eligible reason: failedNoRetry, classifier stays nil, loader called once"
  )
  func typedErrorFailsNoRetry() async throws {
    let holder = OutputClassifierHolder()
    let spy = CallSpy()
    let outcome = await holder.beginLoadIfNeeded { _ in
      await spy.recordCall()
      throw OutputClassifierError.disabled(.modelLoadFailed)
    }
    #expect(outcome == .failedNoRetry(reason: .modelLoadFailed))
    #expect(holder.classifier == nil)
    // A packaging defect is deterministic regardless of compute path — never
    // retried, even though a retry is technically possible (#1226).
    #expect(await spy.count == 1)
  }

  @Test(
    "repeat call after a typed-error failure: skippedPermanentlyDisabled, loader not invoked again")
  func repeatAfterTypedErrorSkips() async throws {
    let holder = OutputClassifierHolder()
    let spy = CallSpy()
    let first = await holder.beginLoadIfNeeded { _ in
      await spy.recordCall()
      throw OutputClassifierError.disabled(.modelLoadFailed)
    }
    #expect(first == .failedNoRetry(reason: .modelLoadFailed))

    let second = await holder.beginLoadIfNeeded { _ in
      await spy.recordCall()
      throw OutputClassifierError.disabled(.modelLoadFailed)
    }
    #expect(second == .skippedPermanentlyDisabled(reason: .modelLoadFailed))
    #expect(await spy.count == 1)
  }

  // MARK: - #1226 compute-unit fallback

  @Test(
    ".all fails fixtureSelfTestFailed, .cpuAndGPU succeeds: succeededViaFallback, classifier non-nil, loader called twice"
  )
  func fixtureSelfTestFailedThenCpuOnlySucceeds() async throws {
    let holder = OutputClassifierHolder()
    let spy = CallSpy()
    let outcome = await holder.beginLoadIfNeeded { computeUnits in
      await spy.recordCall()
      if computeUnits == .all { throw OutputClassifierError.disabled(.fixtureSelfTestFailed) }
      return StubClassifier(usedFallbackCompute: true)
    }
    #expect(outcome == .succeededViaFallback(primaryReason: .fixtureSelfTestFailed))
    #expect(holder.classifier != nil)
    #expect(await spy.count == 2)
  }

  @Test(
    ".all fails fixtureSelfTestFailed, .cpuAndGPU ALSO fails with the SAME reason: failedAfterFallback preserves both"
  )
  func fixtureSelfTestFailedThenCpuOnlyFailsSameReason() async throws {
    let holder = OutputClassifierHolder()
    let spy = CallSpy()
    let outcome = await holder.beginLoadIfNeeded { _ in
      await spy.recordCall()
      throw OutputClassifierError.disabled(.fixtureSelfTestFailed)
    }
    #expect(
      outcome
        == .failedAfterFallback(
          primaryReason: .fixtureSelfTestFailed, fallbackReason: .fixtureSelfTestFailed))
    #expect(holder.classifier == nil)
    #expect(await spy.count == 2)
  }

  @Test(
    ".all fails fixtureSelfTestFailed, .cpuAndGPU fails with a DIFFERENT reason: failedAfterFallback preserves BOTH distinctly"
  )
  func fixtureSelfTestFailedThenCpuOnlyFailsDifferentReason() async throws {
    let holder = OutputClassifierHolder()
    let outcome = await holder.beginLoadIfNeeded { computeUnits in
      if computeUnits == .all { throw OutputClassifierError.disabled(.fixtureSelfTestFailed) }
      throw OutputClassifierError.disabled(.inferenceError)
    }
    #expect(
      outcome
        == .failedAfterFallback(
          primaryReason: .fixtureSelfTestFailed, fallbackReason: .inferenceError))
  }

  @Test(
    "cancellation during the FALLBACK attempt: failedRetryable, state resets to notStarted (not disabled)"
  )
  func cancellationDuringFallbackAttemptIsRetryable() async throws {
    let holder = OutputClassifierHolder()
    let outcome = await holder.beginLoadIfNeeded { computeUnits in
      if computeUnits == .all { throw OutputClassifierError.disabled(.fixtureSelfTestFailed) }
      throw CancellationError()
    }
    #expect(outcome == .failedRetryable(errorCategory: "cancelled"))
    #expect(holder.classifier == nil)

    // notStarted, not disabled — a cancelled retry is not evidence of brokenness.
    let second = await holder.beginLoadIfNeeded { _ in StubClassifier() }
    #expect(second == .succeeded)
  }

  @Test("repeat call after success: skippedAlreadyReady, loader not invoked again")
  func repeatAfterSuccessSkips() async throws {
    let holder = OutputClassifierHolder()
    let spy = CallSpy()
    let first = await holder.beginLoadIfNeeded { _ in
      await spy.recordCall()
      return StubClassifier()
    }
    #expect(first == .succeeded)

    let second = await holder.beginLoadIfNeeded { _ in
      await spy.recordCall()
      return StubClassifier()
    }
    #expect(second == .skippedAlreadyReady)
    #expect(await spy.count == 1)
  }

  @Test(
    "concurrent trigger while a load is in flight: the second caller coalesces, never invokes its own loader"
  )
  func concurrentTriggerCoalesces() async throws {
    let holder = OutputClassifierHolder()
    let spy = CallSpy()
    let gate = ReleaseGate()
    let started = AsyncStream.makeStream(of: Void.self)
    let startedContinuation = started.continuation

    // First call: parks on the gate after signaling it has actually started
    // the load (proves `state == .loading` before the second call runs).
    let firstTask = Task { @MainActor in
      await holder.beginLoadIfNeeded { _ in
        await spy.recordCall()
        startedContinuation.yield(())
        startedContinuation.finish()
        await gate.wait()
        return StubClassifier()
      }
    }

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()  // first call is parked inside its loader

    // Second call arrives while the first is still loading — must coalesce
    // without ever calling its own loader.
    let secondOutcome = await holder.beginLoadIfNeeded { _ in
      await spy.recordCall()
      return StubClassifier()
    }
    #expect(secondOutcome == .skippedLoadInProgress)
    #expect(await spy.count == 1)  // only the first call's loader ran

    await gate.release()
    let firstOutcome = await firstTask.value
    #expect(firstOutcome == .succeeded)
    #expect(holder.classifier != nil)
    #expect(await spy.count == 1)
  }

  @Test("CancellationError: failedRetryable, a later call retries")
  func cancellationIsRetryable() async throws {
    let holder = OutputClassifierHolder()
    let spy = CallSpy()
    let first = await holder.beginLoadIfNeeded { _ in
      await spy.recordCall()
      throw CancellationError()
    }
    #expect(first == .failedRetryable(errorCategory: "cancelled"))
    #expect(holder.classifier == nil)

    let second = await holder.beginLoadIfNeeded { _ in
      await spy.recordCall()
      return StubClassifier()
    }
    #expect(second == .succeeded)
    #expect(await spy.count == 2)  // retried — not permanently disabled
  }

  @Test("unmapped error: failedRetryable, a later call retries")
  func unmappedErrorIsRetryable() async throws {
    struct SomeOtherError: Error {}
    let holder = OutputClassifierHolder()
    let spy = CallSpy()
    let first = await holder.beginLoadIfNeeded { _ in
      await spy.recordCall()
      throw SomeOtherError()
    }
    #expect(first == .failedRetryable(errorCategory: "unknown_load_error"))
    #expect(holder.classifier == nil)

    let second = await holder.beginLoadIfNeeded { _ in
      await spy.recordCall()
      return StubClassifier()
    }
    #expect(second == .succeeded)
    #expect(await spy.count == 2)
  }

  /// The remaining 7 `OutputClassifierDisabledReason` variants not already
  /// covered by `fixtureSelfTestFailedThenCpuOnly*` — none is
  /// `isRetryEligibleForComputeFallback`, so each proves a single-attempt
  /// `.failedNoRetry` (a packaging defect a different compute path cannot fix).
  @Test(
    "typed OutputClassifierError, non-retry-eligible reasons, preserve reason through to failedNoRetry",
    arguments: [
      OutputClassifierDisabledReason.contractHashMismatch,
      .missingFile,
      .unsupportedFamily,
      .shapeMismatch,
      .inferenceError,
      .tokenizerLoadFailed,
      .modelLoadFailed,
    ]
  )
  func typedErrorPreservesReason(_ reason: OutputClassifierDisabledReason) async throws {
    #expect(!reason.isRetryEligibleForComputeFallback)
    let holder = OutputClassifierHolder()
    let outcome = await holder.beginLoadIfNeeded { _ in
      throw OutputClassifierError.disabled(reason)
    }
    #expect(outcome == .failedNoRetry(reason: reason))
  }

  @Test("isRetryEligibleForComputeFallback is true for exactly fixtureSelfTestFailed")
  func isRetryEligibleForComputeFallbackIsExactlyOneCase() {
    #expect(OutputClassifierDisabledReason.fixtureSelfTestFailed.isRetryEligibleForComputeFallback)
    for reason: OutputClassifierDisabledReason in [
      .contractHashMismatch, .missingFile, .unsupportedFamily, .shapeMismatch, .inferenceError,
      .tokenizerLoadFailed, .modelLoadFailed,
    ] {
      #expect(!reason.isRetryEligibleForComputeFallback)
    }
  }
}
