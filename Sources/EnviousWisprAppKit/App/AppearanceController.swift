import AppKit
import EnviousWisprCore

/// Maps the user's `AppearancePreference` onto `NSApplication.appearance`.
/// Stateless: the persisted preference lives on `SettingsManager`; this only
/// applies it. `.system` clears the override so macOS drives appearance and
/// repaints live when the OS setting changes.
@MainActor
enum AppearanceController {
  static func apply(_ preference: AppearancePreference) {
    // `NSApplication.shared` (not the `NSApp` global) — `NSApp` is an
    // implicitly-unwrapped `NSApplication!` that is nil until `.shared` is first
    // accessed, and this runs from `WisprBootstrapper.init` before that happens.
    NSApplication.shared.appearance =
      switch preference {
      case .system: nil
      case .light: NSAppearance(named: .aqua)
      case .dark: NSAppearance(named: .darkAqua)
      }
  }
}
