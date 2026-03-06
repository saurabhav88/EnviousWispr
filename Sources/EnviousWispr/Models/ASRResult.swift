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

/// Options controlling transcription behavior (shared across all backends).
struct TranscriptionOptions: Sendable {
    var language: String?
    var enableTimestamps: Bool = true

    static let `default` = TranscriptionOptions()
}
