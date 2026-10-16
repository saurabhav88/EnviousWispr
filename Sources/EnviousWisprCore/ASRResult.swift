import Foundation

/// The type of ASR backend used for transcription.
public enum ASRBackendType: String, Codable, Sendable {
  case parakeet
  /// #3735: the Whisper engine slot, now served by transcribe.cpp. Stored as
  /// `"whisper"`; builds before #3735 stored `"whisperKit"`, which still
  /// decodes here so saved settings and History rows keep their engine.
  case whisper

  /// Explicit so the legacy `"whisperKit"` spelling decodes. Codable's
  /// `RawRepresentable` conformance calls this initializer, so settings,
  /// History rows and every other stored copy accept both spellings; any
  /// other value stays `nil` (settings fall back to the default, History
  /// rows fail decoding and are skipped, as before).
  public init?(rawValue: String) {
    switch rawValue {
    case "parakeet": self = .parakeet
    case "whisper", "whisperKit": self = .whisper
    default: return nil
    }
  }

  public var displayName: String {
    switch self {
    // #3546: the backend, not a model version. History rows were produced by
    // v3 or by Ultra, and this label is stored-row-agnostic; the model name
    // comes from `ParakeetModel.displayName` where a serving model is known.
    case .parakeet: return "Parakeet"
    case .whisper: return "Whisper"
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

/// One engine segment's span of `ASRResult.text` with its time on the original audio, for an
/// engine that reports segment timing but no word timing (#3735 §3.10: transcribe.cpp whisper).
///
/// `range` is real text (UTF-16 offsets into `text`, ascending, never overlapping); the text
/// is never changed to fit a segment. `startMs`/`endMs` are on the ORIGINAL input timeline
/// and `nil` when the engine's bounds were invalid or fell outside the real audio. A segment
/// whose text could not be located in `text` is absent rather than guessed. Segment timing is
/// never interpolated into `ASRWordTiming`, so it never counts as word-timing coverage.
public struct ASRSegmentTiming: Sendable, Codable, Equatable {
  public let range: Range<Int>
  public let startMs: Int?
  public let endMs: Int?

  public init(range: Range<Int>, startMs: Int?, endMs: Int?) {
    self.range = range
    self.startMs = startMs
    self.endMs = endMs
  }

  /// Both bounds present, non-negative and of positive length: the only bounds that can
  /// overlap a speaker interval. The one test shared by speaker assembly and the retry
  /// decision, so they cannot disagree.
  public var hasUsableBounds: Bool {
    guard let startMs, let endMs else { return false }
    return startMs >= 0 && endMs > startMs
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
  /// Segment-level timing (#3735 §3.10), from an engine with no word timing. `nil` when
  /// timestamps were not requested or the engine has no segment timing. Optional + defaulted
  /// so existing callers and old Codable payloads still decode.
  public let segmentTimings: [ASRSegmentTiming]?
  /// #3801: trailing segments the Whisper silent-tail filter removed from the decode that
  /// produced `text` (0 = it ran and removed nothing). `nil` for Parakeet and when not measured.
  /// Telemetry metadata only. Optional + defaulted so existing callers and old payloads decode.
  public let silentTailDropped: Int?

  public init(
    text: String, language: String?, duration: TimeInterval, processingTime: TimeInterval,
    backendType: ASRBackendType, tokenTimingSummary: ASRTokenTimingSummary? = nil,
    wordTimings: [ASRWordTiming]? = nil, wordTimingCoverage: ASRWordTimingCoverage? = nil,
    segmentTimings: [ASRSegmentTiming]? = nil, silentTailDropped: Int? = nil
  ) {
    self.text = text
    self.language = language
    self.duration = duration
    self.processingTime = processingTime
    self.backendType = backendType
    self.tokenTimingSummary = tokenTimingSummary
    self.wordTimings = wordTimings
    self.wordTimingCoverage = wordTimingCoverage
    self.segmentTimings = segmentTimings
    self.silentTailDropped = silentTailDropped
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
