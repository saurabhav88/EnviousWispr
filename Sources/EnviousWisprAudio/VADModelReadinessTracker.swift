import Foundation

/// Tracks the bundled VAD model's health across a process's lifetime and
/// decides when the "auto-stop unavailable" notice becomes eligible to show
/// (#1224). Pulled out of `AudioServiceHandler` (which runs inside an XPC
/// service target with no reachable unit-test bundle in this project) so the
/// actual decision logic has real, canonical-build test coverage.
///
/// Classification (`classifyIfNeeded`) happens at most once, ever — a
/// permanently broken bundled file gains nothing from retrying. Notice
/// eligibility (`shouldShowNotice`) is re-checked on EVERY call regardless of
/// when classification happened — a user who had auto-stop off when the
/// model was classified broken must still see the notice the first time they
/// turn auto-stop on and start a recording (council-round-1 fix: a single
/// latch that fired only at classification time silently dropped the notice
/// for exactly this ordering).
public struct VADModelReadinessTracker: Sendable {
  public enum Readiness: Equatable, Sendable {
    case unknown
    case ready
    case broken(reason: String)
  }

  public private(set) var readiness: Readiness = .unknown
  public private(set) var noticeShown = false

  public init() {}

  /// Classify the model's load outcome. No-ops if already classified
  /// (`.ready` or `.broken`) — call sites should only reach this the first
  /// time; calling again is harmless but intentionally has no effect.
  /// - Parameter failureReason: `nil` on success (-> `.ready`); the
  ///   content-free error-type description on failure (-> `.broken`).
  public mutating func classifyIfNeeded(failureReason: String?) {
    guard case .unknown = readiness else { return }
    readiness = failureReason.map { .broken(reason: $0) } ?? .ready
  }

  /// Returns whether the caller should show the notice right now. Fires
  /// `true` at most once, ever, across this tracker's lifetime — and only
  /// when the model is broken, the feature is currently enabled, a recording
  /// is actually live to show it in, and the notice hasn't already fired.
  ///
  /// - Parameter recordingIsLive: whether a recording is currently active.
  ///   Cloud review (PR #1510): the caller's model-load attempt can still be
  ///   in flight after the user has already stopped/cancelled the recording
  ///   (`Task.cancel()` is cooperative; a load in progress doesn't observe
  ///   it). Since this fires at most once EVER, consuming it while no
  ///   recording is live to display it in would silently and permanently
  ///   skip the notice for every later recording — so a not-live call is
  ///   inert: it neither shows the notice nor consumes the one-shot,
  ///   leaving it available for the next live, eligible recording.
  public mutating func shouldShowNotice(autoStopEnabled: Bool, recordingIsLive: Bool) -> Bool {
    guard case .broken = readiness, autoStopEnabled, recordingIsLive, !noticeShown else {
      return false
    }
    noticeShown = true
    return true
  }
}
