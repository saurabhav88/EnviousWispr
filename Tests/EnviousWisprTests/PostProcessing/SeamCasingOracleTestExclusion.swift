import Foundation

@testable import EnviousWisprPostProcessing

/// Cross-SUITE exclusion for the process-wide `SeamCasingOracleRuntime`.
///
/// Modelled on `AppLoggerTestExclusion` (#1361), which exists for the identical
/// problem: `.serialized` orders tests within ONE suite and nothing more, and
/// Swift Testing runs suites concurrently, so two suites touching the same
/// process global interleave at every `await`.
///
/// Until #1921 only `SeamCasingOracleTests` mutated this runtime, and its
/// `.serialized` was sufficient BY ACCIDENT — it was the only participant.
/// `KernelFinalizationWiringTests` deliberately injected a fake oracle instead,
/// with a comment saying mutating the global "would race `SeamCasingOracleTests`".
/// #1921's two deadline tests must assert what the timeout does to the real
/// runtime, so they cannot avoid it, and the accident ends.
///
/// The latch is one-way and process-wide: `disableAfterTimeout()` permanently
/// marks the runtime `.oracleTimedOut`. A suite observing "still enabled" while
/// another suite's timeout test fires is not a flaky assertion, it is a wrong
/// one — so this is a correctness fix, not tidiness.
///
/// Fair FIFO, so a suite cannot be starved by a busy neighbour.
actor SeamCasingOracleTestExclusion {
  static let shared = SeamCasingOracleTestExclusion()

  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  private init() {}

  func acquire() async {
    if !held {
      held = true
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiters.append(continuation)
    }
  }

  func release() {
    if waiters.isEmpty {
      held = false
    } else {
      // Stays `held`; ownership passes straight to the next waiter.
      waiters.removeFirst().resume()
    }
  }
}

/// Runs `body` with exclusive access to `SeamCasingOracleRuntime`, then resets
/// it so the next holder starts from a known state.
///
/// Free function, NOT a method on the actor: as a method the caller's closure
/// would be sent across the actor boundary, and a `@MainActor` test body is not
/// `Sendable`. Keeping only `acquire`/`release` on the actor lets `body` run in
/// whatever isolation the caller already has. `isolation: isolated (any Actor)?
/// = #isolation` makes this INHERIT that isolation rather than hopping off it;
/// without it a `@MainActor` suite cannot pass its body at all under Swift 6.
///
/// **Snapshots the prior runtime and RESTORES it before releasing**, on the
/// throwing path too.
///
/// An earlier draft of this helper simply reset the runtime on the way out, on
/// the reasoning that a one-way latch has no state worth preserving. That was
/// wrong in one direction I did not check: a holder that arrives after a suite
/// has legitimately prewarmed the runtime would have that prewarm destroyed, and
/// every later reader would see `oracleWarming` instead of the real oracle.
/// Borrowing shared state means giving it back as you found it.
///
/// Order matters and is the #1361 lesson: reset FIRST, then reinstall, because a
/// teardown that resets after restoring undoes its own restore. A genuinely
/// warming prior state needs no reinstall — the reset already reproduces it.
///
/// A leaked hold would deadlock every other participating suite for the rest of
/// the run, so restoration and release happen on both exits.
func withSeamCasingOracleExclusion<T>(
  isolation: isolated (any Actor)? = #isolation,
  _ body: () async throws -> T
) async rethrows -> T {
  await SeamCasingOracleTestExclusion.shared.acquire()

  let prior = SeamCasingOracleRuntime.snapshot()

  @Sendable func restoreAndRelease() async {
    SeamCasingOracleRuntime.resetForTesting()
    // `oracleWarming` IS what a reset produces, so reinstalling it would be a
    // no-op at best. Any other prior state was a real oracle this holder must
    // hand back.
    if prior.unavailableReason != .oracleWarming {
      SeamCasingOracleRuntime.installForTesting(prior)
    }
    await SeamCasingOracleTestExclusion.shared.release()
  }

  do {
    let value = try await body()
    await restoreAndRelease()
    return value
  } catch {
    await restoreAndRelease()
    throw error
  }
}
