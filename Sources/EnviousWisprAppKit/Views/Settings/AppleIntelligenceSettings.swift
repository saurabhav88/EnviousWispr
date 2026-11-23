import Foundation

/// Existing System Settings destination, validated on macOS 26.6 (#1080).
/// Kept internal so the onboarding test can assert the URL. Newer macOS may show
/// different controls; the guidance does not promise a switch or a repair (#4016).
/// #4528 M23: its own file, so Settings keeps it when chunk D deletes the old onboarding view.
enum AppleIntelligenceSettings {
  static let systemSettingsURL = "x-apple.systempreferences:com.apple.Siri-Settings.extension"
}
