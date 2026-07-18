import EnviousWisprCore
import EnviousWisprLLM
import Foundation
import Testing

@testable import EnviousWisprServices

/// #1525 PR I-C: end-to-end proof that `LLMTelemetrySink.makeLive(...)` maps a real
/// `legacyKeyCleanupFailed` call onto BOTH production effects — the `limb.failure_observed`
/// population event and the `legacyKeyCleanupFailed` handled-error capture — using a real,
/// conforming `KeyStoreError`. Constructs its own sink instance via per-instance injected
/// reporters (no process-global mutable delegate — `swift-patterns.md` RULE:
/// tests-no-process-global-mutable-delegate), mirroring `KernelDictationDriverFactory`'s
/// existing `HeartPathCaptureErrorSink` precedent.
@Suite("LLMTelemetrySink.makeLive production adapter (#1525 PR I-C)")
@MainActor
struct LLMTelemetrySinkLiveTests {
  private struct CapturedLimbFailure {
    let limb: String
    let operation: String
    let result: String
    let errorCategory: String
    let durationMs: Int?
  }

  private struct CapturedHandledError {
    // #1525 PR J-1: `HandledErrorReporter` narrowed — the stored field must
    // match so the value can be replayed into `makeHandledErrorEvent` below.
    let error: any Error & StableSentryErrorIdentity
    let category: SentryBreadcrumb.ErrorCategory
    let stage: String
    let extra: [String: Any]?
    let fingerprintDetail: String?
  }

  /// Per-test, per-instance waiter — no process-global state. Both reporters fire
  /// synchronously, back-to-back, inside the SAME `DispatchQueue.main.async` hop
  /// (`limbFailureReporter` then `handledErrorReporter`), so awaiting the handled-error
  /// reporter's arrival is sufficient: the limb-failure reporter has already run by then.
  ///
  /// Codex r5 finding: an unconditional `withCheckedContinuation` here would hang the
  /// test forever if a future regression stopped the adapter invoking the reporter —
  /// `awaitHandled` takes a bounded deadline instead (`swift-patterns.md`
  /// `tests-no-unconditional-continuation-await`), throwing `TimeoutError` on expiry so
  /// a broken wire fails fast with a clear signal instead of hanging the whole suite.
  private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var limb: CapturedLimbFailure?
    private var handled: CapturedHandledError?
    private var continuation: CheckedContinuation<Void, any Error>?

    func recordLimb(_ value: CapturedLimbFailure) {
      lock.lock()
      limb = value
      lock.unlock()
    }

    func recordHandled(_ value: CapturedHandledError) {
      lock.lock()
      handled = value
      let pending = continuation
      continuation = nil
      lock.unlock()
      pending?.resume()
    }

    func snapshot() -> (CapturedLimbFailure?, CapturedHandledError?) {
      lock.lock()
      defer { lock.unlock() }
      return (limb, handled)
    }

    /// Synchronous — called only from inside the continuation closures below, never
    /// directly in an async body (`NSLock.lock`/`.unlock` are unavailable from
    /// asynchronous contexts under strict concurrency checking). Returns whether the
    /// continuation was armed (false means it was already resumed synchronously).
    private func armWaiter(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
      lock.lock()
      if handled != nil {
        lock.unlock()
        continuation.resume()
        return false
      }
      self.continuation = continuation
      lock.unlock()
      return true
    }

    private func timeoutWaiter(seconds: Double) {
      lock.lock()
      let pending = continuation
      continuation = nil
      lock.unlock()
      pending?.resume(throwing: TimeoutError(seconds: seconds))
    }

    func awaitHandled(timeout: Duration = .seconds(5)) async throws {
      let seconds =
        Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
      try await withCheckedThrowingContinuation { continuation in
        guard armWaiter(continuation) else { return }
        Task { [weak self] in
          // deadline-fallback: fail fast if the handled-error reporter never fires
          try? await Task.sleep(for: timeout)
          self?.timeoutWaiter(seconds: seconds)
        }
      }
    }
  }

  @Test(
    "legacyKeyCleanupFailed reports both the population event and the handled error, with the real KeyStoreError identity"
  )
  func legacyKeyCleanupFailedReportsBothEffects() async throws {
    let box = ResultBox()
    let sink = LLMTelemetrySink.makeLive(
      limbFailureReporter: { limb, operation, result, errorCategory, durationMs in
        box.recordLimb(
          CapturedLimbFailure(
            limb: limb, operation: operation, result: result,
            errorCategory: errorCategory, durationMs: durationMs))
      },
      handledErrorReporter: { error, category, stage, extra, fingerprintDetail in
        box.recordHandled(
          CapturedHandledError(
            error: error, category: category, stage: stage, extra: extra,
            fingerprintDetail: fingerprintDetail))
      })

    sink.legacyKeyCleanupFailed(KeyStoreError.deleteFailed(-1), "test-account")

    try await box.awaitHandled()
    let (limb, handled) = box.snapshot()

    let limbFailure = try #require(limb)
    #expect(limbFailure.limb == "keychain")
    #expect(limbFailure.operation == "legacy_cleanup")
    #expect(limbFailure.result == "failed")
    #expect(limbFailure.errorCategory == "delete_failed")
    #expect(limbFailure.durationMs == nil)

    let handledError = try #require(handled)
    #expect(handledError.category == .legacyKeyCleanupFailed)
    #expect(handledError.stage == "keychain")
    #expect(handledError.extra?["account"] as? String == "test-account")
    #expect(handledError.fingerprintDetail == "test-account")

    let event = SentryBreadcrumb.makeHandledErrorEvent(
      handledError.error, category: handledError.category, stage: handledError.stage,
      extra: handledError.extra, fingerprintDetail: handledError.fingerprintDetail,
      environment: "test")
    #expect(
      event.fingerprint
        == [
          "handled_error", "legacy_key_cleanup_failed",
          "EnviousWisprLLM.KeyStoreError#2", "test-account", "test",
        ])
    #expect(event.tags?["error.identity"] == "keystore.delete_failed")
  }

  /// Row 10 (#1525 PR J-1): the production conformer always converts (`legacyStore
  /// .delete(key:)`'s only real implementation throws `KeyStoreError`), but the write-site
  /// static type is `any Error` (untyped `throws`) — a genuine miss must still alert under
  /// the fixed `.unexpectedLegacyKeyCleanupFailure` identity, never drop silently.
  @Test(
    "a non-conforming cleanup error still reports both effects, normalized to .unexpectedLegacyKeyCleanupFailure"
  )
  func legacyKeyCleanupFailedNonConformingNormalizesToUnexpected() async throws {
    struct OpaqueCleanupError: Error {}
    let box = ResultBox()
    let sink = LLMTelemetrySink.makeLive(
      limbFailureReporter: { limb, operation, result, errorCategory, durationMs in
        box.recordLimb(
          CapturedLimbFailure(
            limb: limb, operation: operation, result: result,
            errorCategory: errorCategory, durationMs: durationMs))
      },
      handledErrorReporter: { error, category, stage, extra, fingerprintDetail in
        box.recordHandled(
          CapturedHandledError(
            error: error, category: category, stage: stage, extra: extra,
            fingerprintDetail: fingerprintDetail))
      })

    sink.legacyKeyCleanupFailed(OpaqueCleanupError(), "test-account")

    try await box.awaitHandled()
    let (_, handled) = box.snapshot()

    let handledError = try #require(handled)
    #expect(handledError.error.sentrySemanticID == "boundary.unexpected_legacy_key_cleanup_failure")
  }
}
