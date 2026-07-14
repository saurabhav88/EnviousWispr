import Foundation

/// App-wide telemetry state for audio capture diagnostics. Owns dedupe state
/// for zombie-engine zero-peak events (#302).
///
/// Shared across both pipelines so a Parakeet-to-WhisperKit switch does not
/// reset dedupe, and so `timeSinceLastSuccessfulRecordingMs` is an app-level
/// baseline rather than pipeline-local.
@MainActor
public final class CaptureTelemetryState {
  private var lastZombieEmittedAt: ContinuousClock.Instant?
  private var lastZombieRoute: String?
  private var lastSuccessfulRecordingAt: ContinuousClock.Instant?

  private let currentInstant: @MainActor () -> ContinuousClock.Instant

  public init(
    currentInstant: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
  ) {
    self.currentInstant = currentInstant
  }

  /// Called at transcript save (not paste end) so clipboard-only users are
  /// covered. Resets zombie dedupe so a successful recording sandwiched
  /// between two zombie events still surfaces the second event.
  public func recordSuccessfulRecording() {
    lastSuccessfulRecordingAt = currentInstant()
    lastZombieEmittedAt = nil
    lastZombieRoute = nil
  }

  /// Returns true if a zombie event on `route` should emit to Sentry now.
  /// False when a prior event fired less than `window` ago on the same route
  /// with no intervening successful recording.
  public func shouldEmitZombie(route: String, window: Duration) -> Bool {
    guard let last = lastZombieEmittedAt, lastZombieRoute == route else {
      return true
    }
    return currentInstant() - last >= window
  }

  /// Marks that a zombie event was observed (regardless of whether it emitted
  /// to Sentry). The 30s window is relative to the most recent observation,
  /// not the most recent emission, so rapid retries stay suppressed.
  public func markZombieEmitted(route: String) {
    lastZombieEmittedAt = currentInstant()
    lastZombieRoute = route
  }

  /// Milliseconds since the last successful recording. Nil if the app session
  /// has never produced a successful recording yet.
  public func timeSinceLastSuccessfulRecordingMs() -> Int? {
    guard let last = lastSuccessfulRecordingAt else { return nil }
    let elapsed = currentInstant() - last
    let (seconds, attoseconds) = elapsed.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}
