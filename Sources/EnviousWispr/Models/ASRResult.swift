import Foundation

/// The type of ASR backend used for transcription.
enum ASRBackendType: String, Codable, Sendable {
    case parakeet
    case whisperKit

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet v3"
        case .whisperKit: return "WhisperKit"
        }
    }
}

/// Result from an ASR transcription pass.
struct ASRResult: Sendable {
    let text: String
    let language: String?
    let duration: TimeInterval
    let processingTime: TimeInterval
    let backendType: ASRBackendType
}

/// Options controlling transcription behavior.
struct TranscriptionOptions: Sendable {
    var language: String?
    var enableTimestamps: Bool = true

    // WhisperKit quality parameters
    var temperature: Float = 0.0
    var compressionRatioThreshold: Float = 2.4
    var logProbThreshold: Float = -1.0
    var noSpeechThreshold: Float = 0.6
    var skipSpecialTokens: Bool = true
    var usePrefixLanguageToken: Bool = true

    static let `default` = TranscriptionOptions()
}
