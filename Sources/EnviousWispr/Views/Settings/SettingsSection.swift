import SwiftUI

/// Sidebar navigation sections for the unified window.
enum SettingsSection: String, CaseIterable, Identifiable {
    case history
    case speechEngine
    case audio
    case shortcuts
    case aiPolish
    case wordCorrection
    case clipboard
    case memory
    case permissions
    case diagnostics

    var id: String { rawValue }

    var label: String {
        switch self {
        case .history:        return "History"
        case .speechEngine:   return "Speech Engine"
        case .audio:          return "Audio"
        case .shortcuts:      return "Shortcuts"
        case .aiPolish:       return "AI Polish"
        case .wordCorrection: return "Custom Words"
        case .clipboard:      return "Clipboard"
        case .memory:         return "Memory"
        case .permissions:    return "Permissions"
        case .diagnostics:    return "Diagnostics"
        }
    }

    var icon: String {
        switch self {
        case .history:        return "clock.arrow.circlepath"
        case .speechEngine:   return "waveform"
        case .audio:          return "speaker.wave.2"
        case .shortcuts:      return "keyboard"
        case .aiPolish:       return "sparkles"
        case .wordCorrection: return "textformat.abc"
        case .clipboard:      return "clipboard"
        case .memory:         return "memorychip"
        case .permissions:    return "lock.shield"
        case .diagnostics:    return "ladybug"
        }
    }

    var group: SettingsGroup {
        switch self {
        case .history:                              return .app
        case .speechEngine, .audio, .shortcuts:     return .record
        case .aiPolish, .wordCorrection:            return .process
        case .clipboard:                            return .output
        case .memory, .permissions, .diagnostics:  return .system
        }
    }
}

enum SettingsGroup: String, CaseIterable {
    case app     = "APP"
    case record  = "RECORD"
    case process = "PROCESS"
    case output  = "OUTPUT"
    case system  = "SYSTEM"

    var sections: [SettingsSection] {
        SettingsSection.allCases.filter { $0.group == self }
    }
}
