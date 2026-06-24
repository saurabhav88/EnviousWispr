import EnviousWisprCore
import Foundation

/// #1177 (Telemetry Bible Phase 8): the production wiring for the LLM-module quiet-limb
/// sink. The TYPE lives in Core (Foundation-only); THIS `.live` factory lives in
/// Services because it references `TelemetryService` + `SentryBreadcrumb` (Codex
/// grounded review r2: the Core type must not name Services types). The App composition
/// root injects `.live`; every other site uses `.noop`.
extension LLMTelemetrySink {
  /// Maps the Core-owned callbacks onto the real telemetry homes. Both are
  /// `@MainActor` (`TelemetryService` / `SentryBreadcrumb`), and the sink's callers run
  /// off the main actor (A6's `Task.detached`, the off-MainActor Keychain cleanup), so
  /// each closure hops to the main run loop via `DispatchQueue.main.async`
  /// (NOT `Task { @MainActor }`, which may run on the current cycle — gotchas-audio
  /// `dispatch-main-for-runloop-deferral`) and runs the emit there. Fire-and-forget:
  /// telemetry lost to an immediate quit is acceptable; a limb never blocks the heart.
  public static let live = LLMTelemetrySink(
    limbFailure: { limb, operation, result, errorCategory, durationMs in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          TelemetryService.shared.limbFailureObserved(
            limb: limb, operation: operation, result: result,
            errorCategory: errorCategory, durationMs: durationMs)
        }
      }
    },
    legacyKeyCleanupFailed: { error, account in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          // Population event (aggregate cleanup-failure rate) + the security-relevant
          // handled error (per-incident detail). Account name only, never key material.
          TelemetryService.shared.limbFailureObserved(
            limb: "keychain", operation: "legacy_cleanup", result: "failed",
            errorCategory: "delete_failed", durationMs: nil)
          SentryBreadcrumb.captureError(
            error, category: .legacyKeyCleanupFailed, stage: "keychain",
            extra: ["account": account],
            // Split distinct accounts into their own issue (low cardinality: 2 keys).
            fingerprintDetail: account)
        }
      }
    })
}
