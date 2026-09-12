import Foundation

/// One speaker-attributed span of a file-import recording, on the same millisecond clock
/// as `ASRWordTiming`. No FluidAudio type crosses the Audio boundary (#1525 isolation) —
/// `OfflineSpeakerAnalyzer` (Audio) produces this from the vendor's own
/// `TimedSpeakerSegment`.
public struct SpeakerSegment: Sendable, Equatable {
  public let speakerId: String
  public let startMs: Int
  public let endMs: Int
  public let quality: Float

  public init(speakerId: String, startMs: Int, endMs: Int, quality: Float) {
    self.speakerId = speakerId
    self.startMs = startMs
    self.endMs = endMs
    self.quality = quality
  }
}

/// Why the speaker step produced no usable segments. `SpeakerLabeler` (Pipeline) is the
/// only producer.
public enum SpeakerFailure: Sendable, Equatable {
  /// The bundled models could not be loaded (missing or corrupt resource).
  case modelsUnavailable
  /// The analyzer threw; the message is diagnostic only, never shown to the user.
  case analyzerThrew(String)
  /// The analyzer finished without throwing but attributed nothing — a real, distinct
  /// outcome from `analyzerThrew`, which would otherwise misreport a clean run that found
  /// no speech as an error the analyzer raised (found by second-pass review).
  case noSpeakerSegments
  /// Stop, or the coordinator's own generation check, ended the run before it finished.
  case cancelled
}

/// Outcome of the dormant, phase-2 speaker step on one file import.
///
/// `.failed`/`.timedOut` are Fallback signals: the raw words already saved to History are
/// the source of truth, and neither case is surfaced to the user in this phase (§9). Not
/// persisted in phase 2 — held in memory on `FileImportCoordinator` for telemetry and the
/// log only.
public enum SpeakerAnalysis: Sendable, Equatable {
  /// One speaker; still runs the analyzer so the count itself is a real measurement, not
  /// an assumption skipped for a one-voice recording.
  case single(segments: [SpeakerSegment])
  case labeled(count: Int, segments: [SpeakerSegment])
  case failed(SpeakerFailure)
  case timedOut(afterMs: Int)
}
