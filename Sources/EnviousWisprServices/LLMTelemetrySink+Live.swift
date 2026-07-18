import EnviousWisprCore
import Foundation

/// #1177 (Telemetry Bible Phase 8): the production wiring for the LLM-module quiet-limb
/// sink. The TYPE lives in Core (Foundation-only); THIS `.live` factory lives in
/// Services because it references `TelemetryService` + `SentryBreadcrumb` (Codex
/// grounded review r2: the Core type must not name Services types). The App composition
/// root injects `.live`; every other site uses `.noop`.
extension LLMTelemetrySink {
  /// #1525 PR I-C: per-instance injectable reporters, following this project's own
  /// existing `KernelDictationDriverFactory.HeartPathCaptureErrorSink` precedent — a
  /// typealias'd reporter signature + a named production-default constant + an
  /// injectable factory parameter — so a test can construct its own sink and assert
  /// both effects without installing a process-global mutable delegate across an
  /// `await` (`swift-patterns.md` RULE: tests-no-process-global-mutable-delegate).
  package typealias LimbFailureReporter = @MainActor (
    _ limb: String, _ operation: String, _ result: String,
    _ errorCategory: String, _ durationMs: Int?
  ) -> Void

  package typealias HandledErrorReporter = @MainActor (
    _ error: any Error & StableSentryErrorIdentity, _ category: SentryBreadcrumb.ErrorCategory,
    _ stage: String,
    _ extra: [String: Any]?, _ fingerprintDetail: String?
  ) -> Void

  package static let defaultLimbFailureReporter: LimbFailureReporter = {
    limb, operation, result, errorCategory, durationMs in
    TelemetryService.shared.limbFailureObserved(
      limb: limb, operation: operation, result: result,
      errorCategory: errorCategory, durationMs: durationMs)
  }

  package static let defaultHandledErrorReporter: HandledErrorReporter = {
    error, category, stage, extra, fingerprintDetail in
    SentryBreadcrumb.captureError(
      error, category: category, stage: stage, extra: extra,
      fingerprintDetail: fingerprintDetail)
  }

  /// Maps the Core-owned callbacks onto the real telemetry homes. Both reporters are
  /// `@MainActor` (`TelemetryService` / `SentryBreadcrumb`), and the sink's callers run
  /// off the main actor (A6's `Task.detached`, the off-MainActor Keychain cleanup), so
  /// each closure hops to the main run loop via `DispatchQueue.main.async`
  /// (NOT `Task { @MainActor }`, which may run on the current cycle — gotchas-audio
  /// `dispatch-main-for-runloop-deferral`) and runs the emit there. Fire-and-forget:
  /// telemetry lost to an immediate quit is acceptable; a limb never blocks the heart.
  package static func makeLive(
    limbFailureReporter: @escaping LimbFailureReporter = defaultLimbFailureReporter,
    handledErrorReporter: @escaping HandledErrorReporter = defaultHandledErrorReporter
  ) -> LLMTelemetrySink {
    LLMTelemetrySink(
      limbFailure: { limb, operation, result, errorCategory, durationMs in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            limbFailureReporter(limb, operation, result, errorCategory, durationMs)
          }
        }
      },
      legacyKeyCleanupFailed: { error, account in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            // Population event (aggregate cleanup-failure rate) + the security-relevant
            // handled error (per-incident detail). Account name only, never key material.
            limbFailureReporter(
              "keychain", "legacy_cleanup", "failed", "delete_failed", nil)
            // Row 10 (#1525 PR J-1): normalize before calling the narrowed
            // reporter — the production conformer always converts, but the
            // write-site static type is `any Error` (untyped `throws`).
            handledErrorReporter(
              SentryCaptureBoundaryError.normalizingLegacyKeyCleanupFailure(error),
              .legacyKeyCleanupFailed, "keychain", ["account": account], account)
          }
        }
      })
  }

  public static let live = makeLive()
}
