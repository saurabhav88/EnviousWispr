import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLivePreview

/// #4355 PR C: when this fails, live call text shows under the wrong speaker, under a speaker
/// before the model has finished hearing it, or under a speaker from another recording or epoch.
@Suite("Live speaker joiner: one piece, one owner or none", .tags(.productOutcome))
struct LiveSpeakerJoinerTests {
  static let recording = UUID()

  static func span(
    _ start: Int, _ count: Int, recording: UUID = recording, run: Int = 0,
    track: MeetingTrackKind = .callSound
  ) -> MeetingAudioSpan {
    MeetingAudioSpan(
      recording: recording, track: track, run: run, startSample: start, sampleCount: count)!
  }

  static func activity(
    _ start: Int, _ count: Int, _ slots: [Int], epoch: Int = 0, recording: UUID = recording,
    run: Int = 0
  ) -> LiveSpeakerActivity {
    LiveSpeakerActivity(
      epoch: epoch, span: span(start, count, recording: recording, run: run), activeSlots: slots)
  }

  /// A call piece over samples [0, 100).
  static let piece = MeetingTimedPiece(text: "hello there", span: span(0, 100))

  static func assign(_ activities: [LiveSpeakerActivity]) -> LiveSpeakerAssignment {
    LiveSpeakerJoiner.assign(piece, track: .callSound, activities: activities, currentEpoch: 0)
  }

  @Test("microphone text is the user, whatever the call evidence says")
  func microphoneIsYou() {
    let mic = MeetingTimedPiece(text: "hi", span: Self.span(0, 100, track: .microphone))
    #expect(
      LiveSpeakerJoiner.assign(
        mic, track: .microphone, activities: [Self.activity(0, 100, [1])], currentEpoch: 0)
        == .you)
  }

  @Test("call text with no timing stays unresolved")
  func untimedCallTextIsUnresolved() {
    let untimed = MeetingTimedPiece(text: "hi", span: nil)
    #expect(
      LiveSpeakerJoiner.assign(
        untimed, track: .callSound, activities: [Self.activity(0, 100, [1])], currentEpoch: 0)
        == .unresolved)
  }

  @Test("one slot speaking owns the piece; trailing silence and repeated reports do not change that")
  func singleOwnerAssigns() {
    #expect(
      // Speech 70: slot 2 owns 60 (86%), slot 7 owns 10 (14%), reported twice. Counting the
      // repeat would give slot 7 29% and abstain.
      Self.assign([
        Self.activity(0, 60, [2]), Self.activity(60, 20, []), Self.activity(80, 10, [7]),
        Self.activity(80, 10, [7]), Self.activity(90, 10, []),
      ])
        == .remote(epoch: 0, slot: 2))
  }

  @Test(
    "exactly 80/20 assigns; one sample less abstains",
    arguments: [(80, LiveSpeakerAssignment.remote(epoch: 0, slot: 0)), (79, .unresolved)])
  func eightyTwentyBoundary(split: Int, expected: LiveSpeakerAssignment) {
    #expect(
      Self.assign([Self.activity(0, split, [0]), Self.activity(split, 100 - split, [1])])
        == expected)
  }

  @Test("two slots talking over each other abstain (no argmax)")
  func competingOverlapAbstains() {
    #expect(Self.assign([Self.activity(0, 100, [0, 1])]) == .unresolved)
  }

  @Test(
    "silence or missing coverage never invents a speaker",
    arguments: [
      [activity(0, 100, [])],  // analyzed silence: no speech
      [activity(0, 50, [3])],  // only a final prefix: the rest is unknown
      [activity(0, 40, [3]), activity(60, 40, [3])],  // a hole in the middle
    ])
  func noSpeechOrGapsAbstain(activities: [LiveSpeakerActivity]) {
    #expect(Self.assign(activities) == .unresolved)
  }

  @Test(
    "evidence from another recording, run or epoch cannot assign",
    arguments: [
      activity(0, 100, [1], recording: UUID()),
      activity(0, 100, [1], run: 1),
      activity(0, 100, [1], epoch: 1),
    ])
  func foreignEvidenceIsIgnored(foreign: LiveSpeakerActivity) {
    #expect(Self.assign([foreign]) == .unresolved)
  }
}
