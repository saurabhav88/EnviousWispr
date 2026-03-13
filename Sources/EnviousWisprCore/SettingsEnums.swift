import Foundation

/// Tracks which onboarding step the user has reached.
/// Raw values are legacy UserDefaults strings — do NOT change them.
public enum OnboardingState: String, Codable, Sendable {
    case notStarted       = "needsMicPermission"
    case settingUp        = "needsModelDownload"
    case needsPermissions = "needsCompletion"
    case completed        = "completed"
}

public enum EnvironmentPreset: String, CaseIterable, Codable, Sendable {
    case quiet = "quiet"
    case normal = "normal"
    case noisy = "noisy"

    public var vadSensitivity: Float {
        switch self {
        case .quiet: return 0.8
        case .normal: return 0.5
        case .noisy: return 0.2
        }
    }
}

public enum WritingStylePreset: String, CaseIterable, Codable, Sendable {
    case formal = "formal"
    case standard = "standard"
    case friendly = "friendly"
    case custom = "custom"
}
