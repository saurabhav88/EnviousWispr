import EnviousWisprServices
import Foundation

/// Telemetry Bible Phase 7 (#1176): the in-flight onboarding session + its single
/// terminal emit.
///
/// Written by `OnboardingV2View` as the user advances; its terminal methods are
/// called by the App-layer terminal paths — window-close via the existing
/// `onOnboardingDismissed` closure, app-quit via the bootstrapper's terminate
/// forwarding. Owning the guarded emit HERE means no coordinator gains a stored
/// property (those have exact-allowlist ceiling tests) and callers are one-liners.
///
/// Plain `@MainActor final class` (NOT `@Observable`) — nothing renders off it; it
/// is written by the view and read once at terminal, so reactive observation would
/// be pure overhead.
@MainActor
final class OnboardingProgress {
  private var sessionStartedAt: Date?
  private(set) var screen: String = "welcome"
  private(set) var step: String = "welcome"
  private var source: String = "first_run"
  private var terminalEmitted: Bool = false

  /// The current session's start (nil when no session is in flight). The view uses
  /// this as a FLOOR for per-step durations: a reused-window reopen keeps a stale
  /// `stepStartedAt`, so a step completed just after reopen would otherwise report a
  /// duration inflated by the time the window was closed. Flooring at the session
  /// start clamps any step duration to time-spent-in-THIS-session — the box's
  /// session is the single authority for session-scoped timing (cloud Codex r4).
  var sessionStart: Date? { sessionStartedAt }

  /// Called whenever onboarding is presented. Starts a FRESH session only when no
  /// session is in flight — i.e. on a first-run open or a genuine restart (every
  /// terminal, clean-finish or abandon, sets `terminalEmitted`, so the guard lets
  /// the next open reset). A refocus of an already-open window (the status-menu
  /// "Continue Setup…" item re-enters this on the single reused SwiftUI window)
  /// finds a live session and is a no-op — it must NOT rewind the clock (cloud
  /// Codex review PR #1210).
  ///
  /// Deliberately does NOT touch `screen`/`step`: the view owns the position and
  /// pushes it via `update(...)`. Resetting to "welcome" here mislabels the
  /// reused-window reopen-after-abandon case — that window keeps its `viewModel`
  /// and skips `.onAppear`, so no re-sync corrects an assumed "welcome" back to the
  /// real screen; carrying the last observed position is the honest value (cloud
  /// Codex review r2). `source` is supplied by the caller from
  /// `SettingsManager.onboardingEverCompleted` (the durable flag in the SHARED
  /// settings store — Codex code-diff r4: the box must not read the wrong defaults
  /// domain, and the durable completion flag belongs in the settings home).
  func begin(source: String) {
    guard sessionStartedAt == nil || terminalEmitted else { return }
    self.source = source
    sessionStartedAt = Date()
    terminalEmitted = false
  }

  /// Mirror the current screen/step as the user advances (read at terminal).
  func update(screen: String, step: String) {
    self.screen = screen
    self.step = step
  }

  /// Called on a clean finish BEFORE the window closes, so the unguarded
  /// window-close path sees `terminalEmitted` and no-ops (the completed/abandoned
  /// race fix). The durable everCompleted flag is owned by `SettingsManager`
  /// (set when `onboardingState` flips to `.completed`).
  func markCompleted() {
    terminalEmitted = true
  }

  /// The single guarded abandon emit — both the window-close closure and the
  /// app-quit terminate path call this. Emits at most once per session; a clean
  /// finish (`markCompleted`) or a prior abandon suppresses it. Posture is passed
  /// in by the caller so this box does not depend on `PermissionsService`.
  func emitAbandonIfInFlight(reason: String, micStatus: String, accessibilityStatus: String) {
    guard let started = sessionStartedAt, !terminalEmitted else { return }
    terminalEmitted = true
    TelemetryService.shared.onboardingAbandoned(
      screen: screen, step: step,
      elapsedSeconds: Date().timeIntervalSince(started),
      micStatus: micStatus, accessibilityStatus: accessibilityStatus,
      abandonReason: reason, source: source)
  }
}
