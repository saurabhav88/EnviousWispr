import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #4013 r3 F3: when these fail, the rename list offers the user's own name from the call app,
/// drops a name the user typed, offers a name another speaker already has, shows a name from
/// another meeting, or keeps offering a participant list whose audio was deleted.
@Suite("Speaker rename suggestions", .tags(.productOutcome), .timeLimit(.minutes(1)))
@MainActor
struct SpeakerRenameSuggestionsTests {

  @Test("the user's names come first, then the participants without the user, each listed once")
  func combineAndOrder() {
    let suggestions = SpeakerRenameSuggestions(
      roster: ["Alex Rivera", "Saurabh Vaish", "Priya Shah", "Alex Rivera", "Ben Ode"],
      selfNames: ["Saurabh Vaish"], authored: ["Ben Ode", "Dana Lee"], assigned: [:])
    #expect(
      suggestions.names(for: "sys:S1") == ["Ben Ode", "Dana Lee", "Alex Rivera", "Priya Shah"])
  }

  @Test("a name the user typed stays offered even when the call app calls it the user")
  func authoredSelfNameKept() {
    let suggestions = SpeakerRenameSuggestions(
      roster: ["Saurabh Vaish"], selfNames: ["Saurabh Vaish"], authored: ["Saurabh Vaish"],
      assigned: [:])
    #expect(suggestions.names(for: "sys:S1") == ["Saurabh Vaish"])
  }

  @Test("a typed name absent from the participant list is offered")
  func unmatchedAuthored() {
    let suggestions = SpeakerRenameSuggestions(
      roster: ["Alex Rivera"], selfNames: [], authored: ["Dr. Morgan"], assigned: [:])
    #expect(suggestions.names(for: "sys:S1") == ["Dr. Morgan", "Alex Rivera"])
  }

  @Test(
    "a name another speaker shows is left out, also for a speaker not on screen; the speaker's own is kept"
  )
  func assignedElsewhere() {
    let suggestions = SpeakerRenameSuggestions(
      roster: ["Alex Rivera", "Priya Shah", "Dana Lee"], selfNames: [], authored: [],
      // sys:S9 only speaks in hidden echo turns; its name still counts as taken.
      assigned: ["sys:S1": "Alex Rivera", "sys:S2": "Priya Shah", "sys:S9": "Dana Lee"])
    #expect(suggestions.names(for: "sys:S1") == ["Alex Rivera"])
    #expect(suggestions.names(for: "sys:S3").isEmpty)
  }

  @Test("names are compared by their exact characters, never folded together")
  func exactSpelling() {
    let composed = "Ren\u{00E9}e"
    let decomposed = "Rene\u{0301}e"
    let suggestions = SpeakerRenameSuggestions(
      roster: [composed, decomposed, ""], selfNames: [], authored: [], assigned: [:])
    #expect(
      suggestions.names(for: "sys:S1").map { Array($0.utf8) } == [
        Array(composed.utf8), Array(decomposed.utf8),
      ])
  }

  @Test("a change to the suggestions alone makes the inputs differ")
  func equality() {
    let a = SpeakerRenameSuggestions(roster: ["Ana"], selfNames: [], authored: [], assigned: [:])
    let b = SpeakerRenameSuggestions(
      roster: ["Ana"], selfNames: [], authored: ["Ben"], assigned: [:])
    #expect(a != b)
    let inputs = { (s: SpeakerRenameSuggestions) in
      TranscriptTurnsDocument.Inputs(
        rowID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, text: "x", turns: [],
        speakerNames: [:], language: nil, isMeeting: true, mode: .cleaned, timesOn: true,
        documentFinished: true, renameSuggestions: s)
    }
    #expect(inputs(a) != inputs(b))
    #expect(inputs(a) == inputs(a))
  }

  @Test("built from a row: its kept names and speaker names, plus the meeting's roster if read")
  func fromRow() {
    let row = Transcript(
      text: "x", backendType: .parakeet, speakerAnalysis: .labeled(count: 1),
      speakerNames: ["sys:S1": "Alex Rivera"],
      turns: [Turn(id: "t", speakerId: "sys:S1", startMs: 0, endMs: 1, originalTextRange: 0..<1)],
      unassignedSpeakerNames: ["Dana Lee"], meetingID: UUID())
    let withRoster = SpeakerRenameSuggestions(
      row: row, roster: CallSpeakerRoster(names: ["Alex Rivera", "Priya Shah"], selfNames: []))
    #expect(withRoster.names(for: "sys:S2") == ["Dana Lee", "Priya Shah"])
    // No roster (missing or unusable file): the typed names are still offered.
    #expect(SpeakerRenameSuggestions(row: row, roster: nil).names(for: "sys:S2") == ["Dana Lee"])
  }

  @Test("the coordinator reads this meeting's saved list, and none once its audio is deleted")
  func coordinatorRoster() async throws {
    let harness = try MeetingCoordinatorTests.Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .ready
    try harness.store.create(record)
    let log = CallSpeakerLog(
      surface: .zoomApp, source: .app, status: .observed, lag: nil, rules: nil,
      roster: CallSpeakerRoster(
        names: ["Alex Rivera", "Saurabh Vaish"], selfNames: ["Saurabh Vaish"]),
      rosterFromParticipantList: true, observations: [])
    try harness.store.saveCallSpeakers(log, meeting: record.id)
    // A second meeting with a damaged file: no list, no error.
    var other = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    other.state = .ready
    try harness.store.create(other)
    try Data("not json".utf8).write(to: harness.store.callSpeakersURL(for: other.id))
    harness.coordinator.launch()
    await MeetingCoordinatorTests.eventually("listed") {
      harness.coordinator.record(id: record.id) != nil
        && harness.coordinator.record(id: other.id) != nil
    }
    #expect(await harness.coordinator.callSpeakerRoster(meetingID: record.id) == log.roster)
    #expect(await harness.coordinator.callSpeakerRoster(meetingID: other.id) == nil)
    #expect(await harness.coordinator.callSpeakerRoster(meetingID: UUID()) == nil)
    await harness.coordinator.deleteAudio(meetingID: record.id)
    #expect(await harness.coordinator.callSpeakerRoster(meetingID: record.id) == nil)
  }
}
