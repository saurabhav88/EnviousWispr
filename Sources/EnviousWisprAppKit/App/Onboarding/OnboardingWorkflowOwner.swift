import Foundation
import Observation

/// Who may run Setup right now (#4528 chunk C2c.2, plan §16 ownership table). Exactly one
/// workflow writes Setup's settings and owns its tasks and timers at a time.
///
/// Until chunk D the old onboarding (`OnboardingV2View`) is the normal live UI. Its setup and
/// warming tasks deliberately outlive its window (OnboardingV2View.swift, `startSetup`'s
/// comment), so a closed window is not proof the old workflow stopped: it reports each task
/// here. The new coordinator runs only as a DEBUG backend session, and only while the old
/// workflow is quiet; while that session runs, the old window may not open.
@MainActor
@Observable
final class OnboardingWorkflowOwner {
  enum Owner: String, Sendable {
    case none, legacy, backend
  }

  /// Old-onboarding tasks still running (setup, warming).
  private(set) var legacyTasks = 0
  private(set) var backendSessionActive = false
  /// Whether the old onboarding window is open or its open is pending (wired to
  /// AppWindowCoordinator, which reserves it before scheduling the open).
  @ObservationIgnored var legacyWindowVisible: () -> Bool = { false }
  /// Installed by the backend session while it owns Setup: Restart Onboarding and app quit reach
  /// the session through these instead of the old onboarding (plan §16 ownership table).
  @ObservationIgnored var backendRestart: (() -> Void)?
  @ObservationIgnored var backendQuit: (() -> Void)?

  var current: Owner {
    if backendSessionActive { return .backend }
    return isLegacyQuiet ? .none : .legacy
  }

  var isLegacyQuiet: Bool { legacyTasks == 0 && !legacyWindowVisible() }

  /// The old window may open only while no backend session owns Setup.
  var legacyMayOpen: Bool { !backendSessionActive }

  /// Old-onboarding work asks first: refused while a backend session owns Setup.
  @discardableResult
  func beginLegacyWork() -> Bool {
    guard !backendSessionActive else { return false }
    legacyTasks += 1
    return true
  }

  func endLegacyWork() { legacyTasks = max(0, legacyTasks - 1) }

  /// Claims Setup for a backend session; false while the old workflow is open or still working.
  func claimBackendSession() -> Bool {
    if backendSessionActive { return true }
    guard isLegacyQuiet else { return false }
    backendSessionActive = true
    return true
  }

  func releaseBackendSession() {
    backendSessionActive = false
    backendRestart = nil
    backendQuit = nil
  }
}
