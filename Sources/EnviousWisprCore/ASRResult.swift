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

/// One word from an `ASRResult.text`, with its position in that text and its
/// time on the audio, when known.
///
/// `range` is always real text (UTF-16 offsets into `text`, never overlapping,
/// ascending in `ASRResult.wordTimings`). `startMs`/`endMs` are `nil` when the
/// engine gave no timing for this span, or when the timing it gave was invalid
/// (end before start, negative, or beyond the audio) — see
/// `WordTimingRangeMapper`, the sole producer of this type.
public struct ASRWordTiming: Sendable, Codable, Equatable {
  public let word: String
  public let range: Range<Int>
  public let startMs: Int?
  public let endMs: Int?

  public init(word: String, range: Range<Int>, startMs: Int?, endMs: Int?) {
    self.word = word
    self.range = range
    self.startMs = startMs
    self.endMs = endMs
  }
}

/// How much of `ASRResult.text` carries a real word timing.
///
/// Both counts are non-whitespace UTF-16 units of `text`: `total` is every
/// such unit, `timed` is the subset that fell inside a matched word with valid
/// timing bounds. A healthy engine that stops returning timings shows up here
/// as `timed == 0` before it shows up anywhere else.
public struct ASRWordTimingCoverage: Sendable, Codable, Equatable {
  public let timed: Int
  public let total: Int

  public init(timed: Int, total: Int) {
    self.timed = timed
    self.total = total
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
  /// Per-word timing over `text`, when the engine was asked for timestamps.
  /// `nil` means the engine gave no timing data at all (Bypass, not Failure) —
  /// `text` is unaffected either way. Optional + defaulted so existing callers
  /// and old Codable payloads still decode.
  public let wordTimings: [ASRWordTiming]?
  /// Paired with `wordTimings`: `nil` exactly when `wordTimings` is `nil`.
  public let wordTimingCoverage: ASRWordTimingCoverage?

  public init(
    text: String, language: String?, duration: TimeInterval, processingTime: TimeInterval,
    backendType: ASRBackendType, tokenTimingSummary: ASRTokenTimingSummary? = nil,
    wordTimings: [ASRWordTiming]? = nil, wordTimingCoverage: ASRWordTimingCoverage? = nil
  ) {
    self.text = text
    self.language = language
    self.duration = duration
    self.processingTime = processingTime
    self.backendType = backendType
    self.tokenTimingSummary = tokenTimingSummary
    self.wordTimings = wordTimings
    self.wordTimingCoverage = wordTimingCoverage
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
