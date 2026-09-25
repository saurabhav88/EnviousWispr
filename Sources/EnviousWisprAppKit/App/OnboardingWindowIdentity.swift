import AppKit
import EnviousWisprCore

/// Finds the Setup window by the scene id SwiftUI sets as its `identifier` (measured 2026-09-25 on
/// macOS 27: `Window(_:id:)` gives the window exactly that id). Never by its title, which is
/// translatable (#3142). SwiftUI names `WindowGroup` windows `<id>-AppWindow-<n>`; that form is
/// accepted too, because a miss here is silent and the id was not measured on older macOS.
enum OnboardingWindowIdentity {
  static func matches(_ window: NSWindow) -> Bool {
    guard let raw = window.identifier?.rawValue else { return false }
    let id = AppConstants.onboardingWindowID
    return raw == id || raw.hasPrefix("\(id)-AppWindow-")
  }
}
