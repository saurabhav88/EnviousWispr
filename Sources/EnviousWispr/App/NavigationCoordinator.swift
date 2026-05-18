import Observation

/// Owns the "open this settings tab next" signal that menu actions and
/// in-app shortcuts hand off to the sidebar. Extracted from AppState per
/// epic #763 (PR2, issue #765).
@MainActor
@Observable
final class NavigationCoordinator {
  private(set) var pendingSection: SettingsSection?

  func request(_ section: SettingsSection) {
    pendingSection = section
  }

  func consume() {
    pendingSection = nil
  }
}
