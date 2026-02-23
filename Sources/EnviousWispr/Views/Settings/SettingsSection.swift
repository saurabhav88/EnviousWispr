import SwiftUI

/// Sidebar navigation sections for the Command Center settings.
enum SettingsSection: String, CaseIterable, Identifiable {
    case speechEngine
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
        case .speechEngine:   return "Speech Engine"
        case .shortcuts:      return "Shortcuts"
        case .aiPolish:       return "AI Polish"
        case .wordCorrection: return "Word Correction"
        case .clipboard:      return "Clipboard"
        case .memory:         return "Memory"
        case .permissions:    return "Permissions"
        case .diagnostics:    return "Diagnostics"
        }
    }

    var icon: String {
        switch self {
        case .speechEngine:   return "waveform"
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
        case .speechEngine, .shortcuts: return .record
        case .aiPolish, .wordCorrection:                 return .process
        case .clipboard:                                 return .output
        case .memory, .permissions, .diagnostics:        return .system
        }
    }
}

enum SettingsGroup: String, CaseIterable {
    case record  = "RECORD"
    case process = "PROCESS"
    case output  = "OUTPUT"
    case system  = "SYSTEM"

    var sections: [SettingsSection] {
        SettingsSection.allCases.filter { $0.group == self }
    }
}
