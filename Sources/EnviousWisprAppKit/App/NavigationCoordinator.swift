import Observation

/// Owns the "open this settings tab next" signal that menu actions and
/// in-app shortcuts hand off to the sidebar. Extracted from the former root state per
/// epic #763 (PR2, issue #765).
@MainActor
@Observable
final class NavigationCoordinator {
  private(set) var pendingDestination: SettingsDestination?

  func request(_ destination: SettingsDestination) {
    pendingDestination = destination
  }

  func consume() {
    pendingDestination = nil
  }
}
