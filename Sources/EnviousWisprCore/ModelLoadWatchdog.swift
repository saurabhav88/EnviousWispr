import Foundation

/// Issue #445: shared constants and types for the model-load watchdog.
///
/// Both `TranscriptionPipeline` (Parakeet) and `WhisperKitPipeline` (WhisperKit)
/// wrap their model-load `await` in a `raceWithTimeout` against this deadline,
/// surface a Sentry/PostHog event on timeout, and trigger service-level
/// recovery (XPC connection invalidate for Parakeet, backend single-flight
/// for WhisperKit).
public enum ModelLoadWatchdog {
  /// Deadline for the model-load `await` before the watchdog fires.
  ///
  /// 20 seconds is a conservative threshold above the 13.966-second cold-load
  /// reference observed in `AppState.swift:950` (single sample, not population
  /// data). With service-level recovery on timeout, a false-positive on a
  /// legitimate slow load just surfaces "tap to retry" — recovery is cheap.
  public static let deadlineMs: UInt64 = 20_000

  /// User-visible recovery message shown when the watchdog fires.
  /// Set on the active pipeline via `setExternalError(...)` after recovery.
  public static let userMessage: String = "Speech engine isn't responding, tap to retry."

  /// Synthetic error type used when capturing the watchdog event to Sentry.
  /// The wedge is silent (no thrown error from the underlying call); we
  /// fabricate one so the existing `SentryBreadcrumb.captureError(...)` API
  /// can record the event with a stable type and category.
  public struct WedgeError: Error, CustomStringConvertible {
    public let stage: String
    public init(stage: String = "model_load") {
      self.stage = stage
    }
    public var description: String { "model load wedged at stage=\(stage)" }
  }
}
