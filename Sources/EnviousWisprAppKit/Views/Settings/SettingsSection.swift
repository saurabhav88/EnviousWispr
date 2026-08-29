import SwiftUI

/// The section a settings page belongs to, set by `UnifiedWindowView` on each
/// page's content so `SettingsContentView` can render the page-header card as
/// its first item without every page wiring it up by hand.
private struct SettingsPageSectionKey: EnvironmentKey {
  static let defaultValue: SettingsSection? = nil
}

extension EnvironmentValues {
  var settingsPageSection: SettingsSection? {
    get { self[SettingsPageSectionKey.self] }
    set { self[SettingsPageSectionKey.self] = newValue }
  }
}

/// A way for a page to send the user to ANOTHER page.
///
/// **Added for the Appearance page's link to Live Preview** (#2446). Picking the
/// pill that shows words switches Live Preview on, and the user then needs
/// somewhere to configure it — which lives on a different page. Threading a
/// binding down through `AppearanceSettingsView` into a panel would put window
/// navigation in the signature of every view in between; the environment is where
/// this window already keeps `settingsPageSection`, one level up.
///
/// Defaults to a no-op rather than to `nil`, so a preview or a test that hosts a
/// panel on its own gets a dead link instead of a crash.
private struct SettingsNavigateKey: EnvironmentKey {
  static let defaultValue: @MainActor (SettingsSection) -> Void = { _ in }
}

extension EnvironmentValues {
  var settingsNavigate: @MainActor (SettingsSection) -> Void {
    get { self[SettingsNavigateKey.self] }
    set { self[SettingsNavigateKey.self] = newValue }
  }
}

/// Sidebar navigation sections for the unified window.
enum SettingsSection: String, CaseIterable, Identifiable {
  case history
  case whatsNew
  case appearance
  case speechEngine
  case livePreview
  case audio
  case recordingSounds
  case keybinds
  case aiPolish
  case wordCorrection
  case clipboard
  case permissions
  case checkForUpdates
  case openSourceLicenses
  #if DEBUG
    case diagnostics
  #endif

  var id: String { rawValue }

  var label: String {
    switch self {
    case .history: return "History"
    case .whatsNew: return "What's New"
    case .appearance: return "Appearance"
    case .speechEngine: return "Transcription"
    case .livePreview: return "Live Preview"
    case .audio: return "Microphone"
    case .recordingSounds: return "Sounds"
    case .keybinds: return "Keybinds"
    case .aiPolish: return "AI Polish"
    case .wordCorrection: return "Dictionary"
    case .clipboard: return "Clipboard"
    case .permissions: return "Permissions"
    case .checkForUpdates: return "Check for Updates"
    case .openSourceLicenses: return "Open Source Licenses"
    #if DEBUG
      case .diagnostics: return "Diagnostics"
    #endif
    }
  }

  var icon: String {
    switch self {
    case .history: return "clock.arrow.circlepath"
    case .whatsNew: return "sparkle.magnifyingglass"
    case .appearance: return "circle.lefthalf.filled"
    case .speechEngine: return "waveform"
    case .livePreview: return "text.viewfinder"
    case .audio: return "speaker.wave.2"
    case .recordingSounds: return "bell.and.waveform"
    case .keybinds: return "keyboard"
    case .aiPolish: return "sparkles"
    case .wordCorrection: return "textformat.abc"
    case .clipboard: return "clipboard"
    case .permissions: return "lock.shield"
    case .checkForUpdates: return "arrow.triangle.2.circlepath"
    case .openSourceLicenses: return "doc.text.magnifyingglass"
    #if DEBUG
      case .diagnostics: return "ladybug"
    #endif
    }
  }

  /// One-line orientation shown under the title in each page's header.
  var subtitle: String {
    switch self {
    case .history: return "Your past dictations, searchable and ready to reuse."
    case .whatsNew: return "The latest improvements and fixes in this release."
    // #2376: widened from "in light and dark" when the recording-pill picker
    // joined this page. The old line described one section rather than the page.
    case .appearance: return "How the app looks, and the pill you see while dictating."
    case .speechEngine: return "The speech engine that turns your voice into text."
    case .livePreview: return "See your words on screen while you are still speaking."
    case .audio: return "Choose your input source and readiness behavior."
    case .recordingSounds: return "Play a short sound when recording starts and stops."
    case .keybinds: return "Set the keybinds that start, stop, and cancel dictation."
    case .aiPolish: return "Clean up and rewrite your dictation with AI."
    case .wordCorrection:
      return "Improve recognition with your words and vocabulary."
    case .clipboard: return "How your transcript reaches the clipboard and the app you're in."
    case .permissions: return "The microphone and accessibility access EnviousWispr needs."
    case .checkForUpdates: return ""
    case .openSourceLicenses:
      return "EnviousWispr is GPLv3 open source. The license and third-party notices."
    #if DEBUG
      case .diagnostics: return "Logs, benchmarks, and debug tools."
    #endif
    }
  }

  var group: SettingsGroup {
    switch self {
    case .history, .whatsNew, .appearance: return .app
    case .speechEngine, .livePreview, .audio, .recordingSounds, .keybinds: return .record
    case .aiPolish, .wordCorrection: return .process
    case .clipboard: return .output
    case .permissions, .checkForUpdates, .openSourceLicenses: return .system
    #if DEBUG
      case .diagnostics: return .system
    #endif
    }
  }
}

enum SettingsGroup: String, CaseIterable {
  case app = "APP"
  case record = "RECORD"
  case process = "PROCESS"
  case output = "OUTPUT"
  case system = "SYSTEM"

  var sections: [SettingsSection] {
    SettingsSection.allCases.filter { $0.group == self }
  }
}
