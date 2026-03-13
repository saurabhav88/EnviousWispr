import Foundation

/// The type of ASR backend used for transcription.
public enum ASRBackendType: String, Codable, Sendable {
    case parakeet
    case whisperKit

    public var displayName: String {
        switch self {
        case .parakeet: return "Parakeet v3"
        case .whisperKit: return "WhisperKit"
        }
    }
}

/// Result from an ASR transcription pass.
public struct ASRResult: Sendable {
    public let text: String
    public let language: String?
    public let duration: TimeInterval
    public let processingTime: TimeInterval
    public let backendType: ASRBackendType

    public init(text: String, language: String?, duration: TimeInterval, processingTime: TimeInterval, backendType: ASRBackendType) {
        self.text = text
        self.language = language
        self.duration = duration
        self.processingTime = processingTime
        self.backendType = backendType
    }
}

/// Options controlling transcription behavior (shared across all backends).
public struct TranscriptionOptions: Sendable {
    public var language: String?
    public var enableTimestamps: Bool = true

    public static let `default` = TranscriptionOptions()

    public init(language: String? = nil, enableTimestamps: Bool = true) {
        self.language = language
        self.enableTimestamps = enableTimestamps
    }
}
