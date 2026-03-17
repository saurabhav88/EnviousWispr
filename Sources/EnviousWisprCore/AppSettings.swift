import Foundation

/// Recording mode for dictation.
public enum RecordingMode: String, Codable, CaseIterable, Sendable {
    case pushToTalk
    case toggle

    public var shortLabel: String {
        switch self {
        case .pushToTalk: return "PTT"
        case .toggle: return "Toggle"
        }
    }
}

/// Pipeline processing state.
public enum PipelineState: Equatable, Sendable {
    case idle
    case loadingModel
    case recording
    case transcribing
    case polishing
    case complete
    case error(String)

    public var isActive: Bool {
        switch self {
        case .loadingModel, .recording, .transcribing, .polishing:
            return true
        default:
            return false
        }
    }

    public var statusText: String {
        switch self {
        case .idle: return "Ready"
        case .loadingModel: return "Loading model..."
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .polishing: return "Polishing..."
        case .complete: return "Done"
        case .error(let msg): return "Error: \(msg)"
        }
    }

}

/// Policy controlling when idle ASR models are unloaded from memory.
public enum ModelUnloadPolicy: String, Codable, CaseIterable, Sendable {
    case never
    case immediately
    case twoMinutes
    case fiveMinutes
    case tenMinutes
    case fifteenMinutes
    case sixtyMinutes

    public var displayName: String {
        switch self {
        case .never:          return "Never"
        case .immediately:    return "Immediately"
        case .twoMinutes:     return "After 2 minutes"
        case .fiveMinutes:    return "After 5 minutes"
        case .tenMinutes:     return "After 10 minutes"
        case .fifteenMinutes: return "After 15 minutes"
        case .sixtyMinutes:   return "After 1 hour"
        }
    }

    /// Returns nil for .never and .immediately (timer-less policies).
    public var interval: TimeInterval? {
        switch self {
        case .never, .immediately: return nil
        case .twoMinutes:          return 120
        case .fiveMinutes:         return 300
        case .tenMinutes:          return 600
        case .fifteenMinutes:      return 900
        case .sixtyMinutes:        return 3600
        }
    }
}
