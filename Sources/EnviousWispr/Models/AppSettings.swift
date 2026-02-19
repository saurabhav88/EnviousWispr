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
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "text.bubble"
        case .polishing: return "sparkles"
        case .complete: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }
}
