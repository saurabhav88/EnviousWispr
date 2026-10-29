import Foundation

/// The durable receipt of one transcript commit (#3973 C2, plan §3 item 5):
/// `transcript-replacement.json` beside `meeting.json`, outside the disposable `work/` folder.
///
/// It is written before the ready barrier and holds the new History row, so a crash, quit or
/// failed History write after the barrier still publishes exactly the committed transcript;
/// before the barrier nothing was committed and the receipt is dropped. It also holds the
/// previous generation's row and History facts, so the transcript shown before a Transcribe
/// again keeps its own probable-echo lines and speaker outcomes until the new one is
/// published. Delete audio keeps it; deleting the meeting removes it with the folder.
public struct MeetingTranscriptReplacement: Sendable, Codable {
  /// Private to this receipt. A build that reads another format leaves the file alone.
  public static let currentFormatVersion = 1

  /// One committed transcript generation's History facts.
  public struct Facts: Sendable, Equatable, Codable {
    public let generation: UUID
    public let echoTurnIDs: [String]
    public let speakerOutcomes: [MeetingTrackKind: MeetingSpeakerOutcome]

    public init(
      generation: UUID, echoTurnIDs: [String],
      speakerOutcomes: [MeetingTrackKind: MeetingSpeakerOutcome]
    ) {
      self.generation = generation
      self.echoTurnIDs = echoTurnIDs
      self.speakerOutcomes = speakerOutcomes
    }
  }

  public let formatVersion: Int
  public let meetingID: UUID
  /// The generation shown before this commit, and its History row; nil for a first transcript.
  public let previous: Facts?
  public let previousRow: Transcript?
  /// The generation this commit makes current, and the History row it publishes.
  public let candidate: Facts
  public let candidateRow: Transcript

  public init(
    meetingID: UUID, previous: Facts?, previousRow: Transcript?, candidate: Facts,
    candidateRow: Transcript
  ) {
    self.formatVersion = Self.currentFormatVersion
    self.meetingID = meetingID
    self.previous = previous
    self.previousRow = previousRow
    self.candidate = candidate
    self.candidateRow = candidateRow
  }
}
