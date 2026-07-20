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

/// Numbers-only summary of an ASR pass's token timings.
///
/// Tail-clip diagnostics (#1232): the engine returns per-token start/end times
/// but the app dropped them. We thread only the count and the end time of the
/// last token (in ms) so we can compute how far the decoded text reached
/// relative to the captured audio. NO token text — release-safe.
public struct ASRTokenTimingSummary: Sendable, Codable {
  public let tokenCount: Int
  /// End time of the final recognized token, in milliseconds. Nil if no tokens.
  public let lastTokenEndMs: Int?

  public init(tokenCount: Int, lastTokenEndMs: Int?) {
    self.tokenCount = tokenCount
    self.lastTokenEndMs = lastTokenEndMs
  }
}

/// Result from an ASR transcription pass.
public struct ASRResult: Sendable, Codable {
  public let text: String
  public let language: String?
  public let duration: TimeInterval
  public let processingTime: TimeInterval
  public let backendType: ASRBackendType
  /// Numbers-only token-timing summary, when the backend exposes it (Parakeet).
  /// Optional + defaulted so existing callers and old Codable payloads still decode.
  public let tokenTimingSummary: ASRTokenTimingSummary?

  public init(
    text: String, language: String?, duration: TimeInterval, processingTime: TimeInterval,
    backendType: ASRBackendType, tokenTimingSummary: ASRTokenTimingSummary? = nil
  ) {
    self.text = text
    self.language = language
    self.duration = duration
    self.processingTime = processingTime
    self.backendType = backendType
    self.tokenTimingSummary = tokenTimingSummary
  }
}

/// Options controlling transcription behavior (shared across all backends).
public struct TranscriptionOptions: Sendable, Codable {
  public var language: String?
  public var enableTimestamps: Bool = true
  public var speechSegments: [SpeechSegment] = []

  public static let `default` = TranscriptionOptions()

  public init(
    language: String? = nil,
    enableTimestamps: Bool = true,
    speechSegments: [SpeechSegment] = []
  ) {
    self.language = language
    self.enableTimestamps = enableTimestamps
    self.speechSegments = speechSegments
  }
}
