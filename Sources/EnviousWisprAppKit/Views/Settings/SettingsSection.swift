import SwiftUI

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
    #if DEBUG
      case .diagnostics: return "ladybug"
    #endif
    }
  }

  var group: SettingsGroup {
    switch self {
    case .history, .whatsNew, .appearance: return .app
    case .speechEngine, .audio, .shortcuts: return .record
    case .aiPolish, .wordCorrection: return .process
    case .clipboard: return .output
    case .permissions, .checkForUpdates: return .system
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
