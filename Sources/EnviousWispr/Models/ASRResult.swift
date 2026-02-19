import Foundation

/// The type of ASR backend used for transcription.
enum ASRBackendType: String, Codable, CaseIterable, Sendable {
    case parakeet
    case whisperKit
}

/// Result from an ASR transcription pass.
struct ASRResult: Sendable {
    let text: String
    let segments: [TranscriptSegment]
    let language: String?
    let duration: TimeInterval
    let processingTime: TimeInterval
    let confidence: Float?
    let backendType: ASRBackendType
}

/// A segment of transcribed audio with timing info.
struct TranscriptSegment: Codable, Sendable {
    let text: String
    let startTime: Float
    let endTime: Float
}

/// Options controlling transcription behavior.
struct TranscriptionOptions: Sendable {
    var language: String?
    var enableTimestamps: Bool = true

    static let `default` = TranscriptionOptions()
}
