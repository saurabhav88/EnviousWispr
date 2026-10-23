import Foundation
import Testing

/// Cross-SUITE exclusion for `ClipboardCleanup`'s process-wide state (#3986).
///
/// `ClipboardCleanup` keeps its pending restore, its active takeover and its superseded tokens in
/// static storage, and four suites drive it across `await`s: `ClipboardCleanupTests`,
/// `ClipboardCleanupLandingTests`, `ManualClipboardTransactionTests` and
/// `SelectionAcquisitionLadderTests`. `.serialized` orders tests within ONE suite only, so without
/// this one suite's `resetPendingForTests()` can cancel another's pending restore, or erase a
/// takeover the other is in the middle of. Separate named pasteboards do not isolate it.
///
/// Ported whole from `AppLoggerTestExclusion` (fair FIFO; release hands ownership to the next
/// waiter). Applied as a trait so every test case of a marked suite runs inside the hold, and the
/// suite instance (whose `init` resets the state) is created inside it too.
actor ClipboardCleanupTestExclusion {
  static let shared = ClipboardCleanupTestExclusion()

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

/// `.clipboardCleanupExclusive`: run each test case of the marked suite holding the exclusion.
struct ClipboardCleanupExclusiveTrait: SuiteTrait, TestTrait, TestScoping {
  var isRecursive: Bool { true }

  /// One hold per test case, never one for the suite as well: a suite-level hold around its own
  /// test cases would wait on itself.
  func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
    test.isSuite || testCase == nil ? nil : self
  }

  func provideScope(
    for test: Test, testCase: Test.Case?,
    performing function: @Sendable () async throws -> Void
  ) async throws {
    await ClipboardCleanupTestExclusion.shared.acquire()
    do {
      try await function()
      await ClipboardCleanupTestExclusion.shared.release()
    } catch {
      // A leaked hold would stall every other clipboard suite for the rest of the run.
      await ClipboardCleanupTestExclusion.shared.release()
      throw error
    }
  }
}

extension Trait where Self == ClipboardCleanupExclusiveTrait {
  static var clipboardCleanupExclusive: Self { Self() }
}
