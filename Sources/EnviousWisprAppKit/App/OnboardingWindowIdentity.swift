import AppKit
import EnviousWisprCore

/// Finds the Setup window by the scene id SwiftUI sets as its `identifier` (measured 2026-09-25:
/// `Window(_:id:)` gives the window that id). Never by its title, which is translatable (#3142).
enum OnboardingWindowIdentity {
  static func matches(_ window: NSWindow) -> Bool {
    window.identifier?.rawValue == AppConstants.onboardingWindowID
  }
}
