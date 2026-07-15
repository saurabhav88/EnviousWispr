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

/// Sidebar navigation sections for the unified window.
enum SettingsSection: String, CaseIterable, Identifiable {
  case history
  case whatsNew
  case appearance
  case speechEngine
  case audio
  case shortcuts
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
    case .audio: return "Microphone"
    case .shortcuts: return "Shortcuts"
    case .aiPolish: return "AI Polish"
    case .wordCorrection: return "Your Words"
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
    case .audio: return "speaker.wave.2"
    case .shortcuts: return "keyboard"
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
    case .appearance: return "Choose how EnviousWispr looks in light and dark."
    case .speechEngine: return "The speech engine that turns your voice into text."
    case .audio: return "Choose your input source and readiness behavior."
    case .shortcuts: return "Set the hotkeys that start, stop, and cancel dictation."
    case .aiPolish: return "Clean up and rewrite your dictation with AI."
    case .wordCorrection:
      return "Custom terms and vocabulary the app uses to recognize what you say."
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
    case .speechEngine, .audio, .shortcuts: return .record
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
