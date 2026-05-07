import Foundation

/// Issue #445: shared constants and types for the model-load watchdog.
///
/// `TranscriptionPipeline` (Parakeet) wraps its model-load `await` in
/// `raceWithSignalWatcher` against a `LoadProgressWatcher`, surfaces a
/// Sentry/PostHog event on wedge, and triggers service-level recovery via
/// `asrManager.cancelInFlightLoad()` (XPC connection invalidate, host task
/// cancel, fresh helper on next press).
///
/// The wall-clock `deadlineMs` constant from the prior design is gone; the
/// trigger is now signal-based (`LoadProgressWatcher`). `WedgeError` and
/// `userMessage` remain because the recovery surface (Sentry event +
/// user-visible "tap to retry" overlay) is unchanged.
public enum ModelLoadWatchdog {
  /// User-visible recovery message shown when the watcher fires.
  /// Set on the active pipeline via `setExternalError(...)` after recovery.
  public static let userMessage: String = "Speech engine isn't responding, tap to retry."

  /// Synthetic error type used when capturing the wedge to Sentry.
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
