import Foundation
import Testing

@testable import EnviousWisprLLM

/// #1452: `OutputClassifierHolder`'s process-lifetime state machine. Proves the
/// actual acceptance criterion — at most one terminal `.failedFirstTime` per
/// process per disablement, concurrent triggers coalesce onto one load, and a
/// non-classifier-fault error (cancellation / unmapped) stays retryable —
/// without touching CoreML, Sentry, or PostHog at all (the loader is a fake
/// closure injected via `beginLoadIfNeeded`).
@MainActor
@Suite("OutputClassifierHolder state machine")
struct OutputClassifierHolderStateTests {

  /// A trivial `OutputClassifierProtocol` for the `.succeeded` path — never
  /// scored in these tests, only used to prove `.classifier` becomes non-nil.
  private struct StubClassifier: OutputClassifierProtocol {
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
    let outcome = await holder.beginLoadIfNeeded {
      await spy.recordCall()
      return StubClassifier()
    }
    #expect(outcome == .succeeded)
    #expect(holder.classifier != nil)
    #expect(await spy.count == 1)
  }

  @Test("typed OutputClassifierError: failedFirstTime, classifier stays nil")
  func typedErrorFailsFirstTime() async throws {
    let holder = OutputClassifierHolder()
    let outcome = await holder.beginLoadIfNeeded {
      throw OutputClassifierError.disabled(.fixtureSelfTestFailed)
    }
    #expect(outcome == .failedFirstTime(reason: .fixtureSelfTestFailed))
    #expect(holder.classifier == nil)
  }

  @Test(
    "repeat call after a typed-error failure: skippedPermanentlyDisabled, loader not invoked again")
  func repeatAfterTypedErrorSkips() async throws {
    let holder = OutputClassifierHolder()
    let spy = CallSpy()
    let first = await holder.beginLoadIfNeeded {
      await spy.recordCall()
      throw OutputClassifierError.disabled(.modelLoadFailed)
    }
    #expect(first == .failedFirstTime(reason: .modelLoadFailed))

    let second = await holder.beginLoadIfNeeded {
      await spy.recordCall()
      throw OutputClassifierError.disabled(.modelLoadFailed)
    }
    #expect(second == .skippedPermanentlyDisabled(reason: .modelLoadFailed))
    #expect(await spy.count == 1)
  }

  @Test("repeat call after success: skippedAlreadyReady, loader not invoked again")
  func repeatAfterSuccessSkips() async throws {
    let holder = OutputClassifierHolder()
    let spy = CallSpy()
    let first = await holder.beginLoadIfNeeded {
      await spy.recordCall()
      return StubClassifier()
    }
    #expect(first == .succeeded)

    let second = await holder.beginLoadIfNeeded {
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
      await holder.beginLoadIfNeeded {
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
    let secondOutcome = await holder.beginLoadIfNeeded {
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
    let first = await holder.beginLoadIfNeeded {
      await spy.recordCall()
      throw CancellationError()
    }
    #expect(first == .failedRetryable(errorCategory: "cancelled"))
    #expect(holder.classifier == nil)

    let second = await holder.beginLoadIfNeeded {
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
    let first = await holder.beginLoadIfNeeded {
      await spy.recordCall()
      throw SomeOtherError()
    }
    #expect(first == .failedRetryable(errorCategory: "unknown_load_error"))
    #expect(holder.classifier == nil)

    let second = await holder.beginLoadIfNeeded {
      await spy.recordCall()
      return StubClassifier()
    }
    #expect(second == .succeeded)
    #expect(await spy.count == 2)
  }

  /// The remaining 7 `OutputClassifierDisabledReason` variants not already
  /// covered by `typedErrorFailsFirstTime` (`.fixtureSelfTestFailed`) — proves
  /// the reason is preserved through to `.failedFirstTime` for every case in
  /// the closed set `CoreMLOutputClassifier.load` can throw.
  @Test(
    "typed OutputClassifierError preserves reason through to failedFirstTime",
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
    let holder = OutputClassifierHolder()
    let outcome = await holder.beginLoadIfNeeded {
      throw OutputClassifierError.disabled(reason)
    }
    #expect(outcome == .failedFirstTime(reason: reason))
  }
}
