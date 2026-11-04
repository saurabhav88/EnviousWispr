import Foundation

/// A stretch of one track's WRITTEN audio, in samples at `MeetingAudioFormat.sampleRate` on the
/// meeting timeline (#4355 plan §3.1).
///
/// The other temporal domain beside `MeetingAcquisitionTime`, with no conversion between them.
/// Only the track writer creates live spans, after masking, trimming and placement, so a span
/// always names audio that is (or will be) in the segment files; persisted spans come back
/// through the one validated segment-decoding adapter. Engine session offsets are session-local
/// and need an explicit projection before they become a span.
///
/// `run` identifies the writer run the samples belong to; a piece of text whose audio crosses
/// runs or an unmapped gap gets no span rather than one stitched across the break.
public struct MeetingAudioSpan: Sendable, Hashable {
  public let recording: UUID
  public let track: MeetingTrackKind
  public let run: Int
  public let startSample: Int
  public let sampleCount: Int

  /// Nil for a negative start, a negative run or an empty or negative count: an empty span
  /// names no audio, so a piece with no audio carries no span rather than an empty one.
  public init?(
    recording: UUID, track: MeetingTrackKind, run: Int, startSample: Int, sampleCount: Int
  ) {
    guard run >= 0, startSample >= 0, sampleCount > 0 else { return nil }
    self.recording = recording
    self.track = track
    self.run = run
    self.startSample = startSample
    self.sampleCount = sampleCount
  }

  /// One past the last sample.
  public var endSample: Int { startSample + sampleCount }
}
