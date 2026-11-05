import Foundation

/// #4355 PR C: what live speaker labels did in one recording, frozen at its stop, for
/// `meeting.ended`. Counts and closed values only; no names, text or audio. A Retry of the
/// recording inherits it, so readers count attempts, not unique recordings.
public struct MeetingLiveSpeakerSummary: Sendable, Equatable {
  /// The speaker model for this recording: not downloaded (or no call sound), still loading at
  /// stop, loaded, or failed to load or run.
  public enum State: String, Sendable, Equatable, CaseIterable {
    case absent
    case loading
    case ready
    case failed
  }

  /// The bundled speaker model's revision; nil when this build has none.
  public let modelRevision: String?
  public let state: State
  /// Words of live call text at stop (every call piece, timed or not, settled or not).
  public let remoteWords: Int
  /// Of those, words shown under a numbered speaker ("Speaker N" or a name).
  public let attributedWords: Int
  /// Speakers showing a call-app name at stop.
  public let namedSpeakers: Int
  /// Call audio the speaker analysis never analysed because its backlog bound dropped it
  /// (`LiveSpeakerSession.droppedSamples`), in milliseconds.
  public let backlogSkippedMs: Int
  /// Model evidence updates dropped at the main-actor handoff (`MeetingLiveSpeakers.Handoff`).
  public let updateDrops: Int
  /// Call audio the speaker pump kept without a written position (its
  /// `Accounting.unpositioned`), in milliseconds. Separate from the live-words pumps'.
  public let unpositionedMs: Int
  /// Audio the live-words pumps (microphone and call sound together) kept without a written
  /// position, in milliseconds: text over it has no timing and stays under "Speaker".
  public let liveWordsUnpositionedMs: Int

  public init(
    modelRevision: String?, state: State, remoteWords: Int, attributedWords: Int,
    namedSpeakers: Int, backlogSkippedMs: Int, updateDrops: Int, unpositionedMs: Int,
    liveWordsUnpositionedMs: Int
  ) {
    self.modelRevision = modelRevision
    self.state = state
    self.remoteWords = remoteWords
    self.attributedWords = attributedWords
    self.namedSpeakers = namedSpeakers
    self.backlogSkippedMs = backlogSkippedMs
    self.updateDrops = updateDrops
    self.unpositionedMs = unpositionedMs
    self.liveWordsUnpositionedMs = liveWordsUnpositionedMs
  }

  /// Attributed words over remote words; nil when there were no remote words.
  public var attributedShare: Double? {
    remoteWords > 0 ? Double(attributedWords) / Double(remoteWords) : nil
  }
}
