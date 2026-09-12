import Foundation

/// One speaker's contiguous stretch of an imported transcript (#2810, phase 3 of #2807).
///
/// Produced by `TurnAssembler` from phase 2's `ASRWordTiming`/`SpeakerSegment` data, then
/// filled in by the background turn-cleanup step. Never rendered before phase 4.
public struct Turn: Sendable, Equatable, Codable {
  /// Deterministic and range-derived, never a random UUID — a fresh `TurnAssembler` pass over
  /// identical input reproduces identical ids, which is what lets a retry (phase 4) compare
  /// old and new turn sets by id rather than by position.
  public let id: String
  /// A real diarizer speaker id, or `"unknown"` for an entry with no confident assignment.
  public let speakerId: String
  /// Minimum start among the turn's fully-timed member entries; `nil` only when NONE of the
  /// turn's entries are timed. An entry assigned to `speakerId == "unknown"` by the
  /// nearest-fallback rule is still "timed" if it has real bounds — timing and speaker
  /// assignment are independent questions.
  public let startMs: Int?
  public let endMs: Int?
  /// UTF-16 offsets into the SAME raw text `Transcript.text` already stores (not a copy).
  /// Spans `first.lowerBound..<last.upperBound` of the turn's member entries — this absorbs
  /// the turn's own intra-turn whitespace but is not gap-free against neighboring turns
  /// (inter-turn and document-edge whitespace belongs to no turn).
  public let originalTextRange: Range<Int>
  /// `nil` until turn-safe cleanup runs for this turn. Once set, joins every part's
  /// `displayText` (polished where available, the deterministic floor otherwise) regardless
  /// of that part's own success.
  public let processedText: String?
  /// `true` if ANY of the turn's cleanup parts polished successfully; `false` only if every
  /// part fell back to its deterministic floor.
  public let wasPolished: Bool

  public init(
    id: String, speakerId: String, startMs: Int?, endMs: Int?,
    originalTextRange: Range<Int>, processedText: String? = nil, wasPolished: Bool = false
  ) {
    self.id = id
    self.speakerId = speakerId
    self.startMs = startMs
    self.endMs = endMs
    self.originalTextRange = originalTextRange
    self.processedText = processedText
    self.wasPolished = wasPolished
  }
}

/// A transcript's speaker-analysis outcome as STORED (distinct from Core's `SpeakerAnalysis`,
/// the analyzer's own in-memory outcome type) — mapped from it, never a second opinion on it.
public enum TranscriptSpeakerAnalysis: Sendable, Equatable, Codable {
  case unanalyzed
  case failed(TranscriptSpeakerFailureReason)
  case single
  case labeled(count: Int)
}

/// A separate persisted vocabulary from `SpeakerFailure` (both live in Core; this is not a
/// module-boundary split). Kept separate for Codable STABILITY — a persisted reason must not
/// reshape when the analyzer's own error type gains a case — and to strip `analyzerThrew`'s
/// free-text diagnostic string before it reaches a stable JSON schema. `.noWordTimings` has no
/// analyzer-side counterpart: it is a merge-input failure (the engine gave no timings to merge
/// against), never an analyzer failure.
public enum TranscriptSpeakerFailureReason: Sendable, Equatable, Codable {
  case modelsUnavailable, analyzerThrew, noSpeakerSegments, cancelled, timedOut, noWordTimings
}

extension SpeakerFailure {
  /// The one exhaustive mapping from the analyzer's in-memory failure to the persisted
  /// reason, stripping `analyzerThrew`'s free-text diagnostic before it reaches a stable
  /// JSON schema. `public` — `FileImportCoordinator` (AppKit) needs it.
  public var asStorageReason: TranscriptSpeakerFailureReason {
    switch self {
    case .modelsUnavailable: return .modelsUnavailable
    case .analyzerThrew: return .analyzerThrew
    case .noSpeakerSegments: return .noSpeakerSegments
    case .cancelled: return .cancelled
    }
  }
}

extension SpeakerAnalysis {
  /// The one exhaustive mapping from the analyzer's in-memory outcome to the persisted
  /// speaker-analysis state (#2810 addendum §3 E). `.noWordTimings` has no counterpart here —
  /// it is a merge-input failure the caller (`FileImportCoordinator`) produces itself when
  /// `ASRResult.wordTimings` is `nil`, before this mapping would ever run.
  public var asStorageAnalysis: TranscriptSpeakerAnalysis {
    switch self {
    case .single: return .single
    case .labeled(let count, _): return .labeled(count: count)
    case .failed(let failure): return .failed(failure.asStorageReason)
    case .timedOut: return .failed(.timedOut)
    }
  }
}
