import Foundation

/// One stretch of the audio a dictation decode read, placed on the saved recording's timeline
/// (#3147 §3.2). `decodeRange` is in samples of the decode input; `recordingStartSample` is where
/// the first sample of that range sits in the recording (the raw capture). Stretches the decode
/// input added (padding) have no span, so they never map onto the recording.
public struct DictationAudioTimelineSpan: Sendable, Equatable {
  public let decodeRange: Range<Int>
  public let recordingStartSample: Int

  public init(decodeRange: Range<Int>, recordingStartSample: Int) {
    self.decodeRange = decodeRange
    self.recordingStartSample = recordingStartSample
  }
}

/// The real word timings of the decode that delivered a dictation's text, with the map from that
/// decode's input to the saved recording (#3147 §3.2). Only evidence the engine actually returned;
/// nothing here is estimated.
public struct DictationTimingEvidence: Sendable, Equatable {
  /// Word timings on the decode input's timeline, ranges into the delivering decode's text.
  public let words: [ASRWordTiming]
  /// Decode input to recording map, ascending, non-overlapping.
  public let timeline: [DictationAudioTimelineSpan]
  /// Sample rate of both the decode input and the recording.
  public let sampleRate: Int

  public init(words: [ASRWordTiming], timeline: [DictationAudioTimelineSpan], sampleRate: Int) {
    self.words = words
    self.timeline = timeline
    self.sampleRate = sampleRate
  }
}
