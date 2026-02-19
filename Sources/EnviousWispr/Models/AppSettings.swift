import Foundation

/// Recording mode for dictation.
enum RecordingMode: String, Codable, CaseIterable, Sendable {
    case pushToTalk
    case toggle
}

/// Pipeline processing state.
enum PipelineState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case polishing
    case complete
    case error(String)

    var isActive: Bool {
        switch self {
        case .recording, .transcribing, .polishing:
            return true
        default:
            return false
        }
    }

    var statusText: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .polishing: return "Polishing..."
        case .complete: return "Done"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var menuBarIconName: String {
        switch self {
        case .idle, .complete, .error:
            return "mic"
        case .recording, .transcribing, .polishing:
            return "mic.fill"
        }
    }

    /// Whether the menu bar icon should pulse (processing states).
    var shouldPulseIcon: Bool {
        switch self {
        case .transcribing, .polishing:
            return true
        default:
            return false
        }
    }
}
