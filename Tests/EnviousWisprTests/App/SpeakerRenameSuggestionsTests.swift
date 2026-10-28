import Dispatch
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

  @Test("equivalent spellings are one name: listed once, as first seen, and filtered as self or taken")
  func canonicalMatching() {
    let composed = "Ren\u{00E9}e"
    let decomposed = "Rene\u{0301}e"
    let once = SpeakerRenameSuggestions(
      roster: [composed, decomposed, "", "renée"], selfNames: [], authored: [], assigned: [:])
    #expect(
      once.names(for: "sys:S1").map { Array($0.utf8) }
        == [Array(composed.utf8), Array("renée".utf8)], "case still counts")
    let asSelf = SpeakerRenameSuggestions(
      roster: [decomposed], selfNames: [composed], authored: [], assigned: [:])
    #expect(asSelf.names(for: "sys:S1").isEmpty)
    let taken = SpeakerRenameSuggestions(
      roster: [decomposed], selfNames: [], authored: [], assigned: ["sys:S2": composed])
    #expect(taken.names(for: "sys:S1").isEmpty)
    // Redraw still sees the different bytes.
    #expect(
      SpeakerRenameSuggestions(roster: [composed], selfNames: [], authored: [], assigned: [:])
        != SpeakerRenameSuggestions(roster: [decomposed], selfNames: [], authored: [], assigned: [:]))
  }

  @Test("a roster read is shown only for the request it answered")
  func keyedRead() {
    let roster = CallSpeakerRoster(names: ["Ana"], selfNames: [])
    let read = KeyedRosterRead(key: "meeting-A", roster: roster)
    #expect(read.roster(for: "meeting-A") == roster)
    #expect(read.roster(for: "meeting-B") == nil, "a switch to another meeting hides it")
    #expect(read.roster(for: nil) == nil)
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

  /// A synchronous wait, called only from a detached task so no actor is blocked.
  // settle: deadline fallback around a semaphore the gated block signals.
  nonisolated static func waitBlocking(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + 10)
  }

  #if DEBUG
  @Test("a read held on the file queue while a deletion starts returns no names")
  func heldReadThenDeletion() async throws {
    let harness = try MeetingCoordinatorTests.Harness()
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = .ready
    try harness.store.create(record)
    try harness.store.saveCallSpeakers(
      CallSpeakerLog(
        surface: .zoomApp, source: .app, status: .observed, lag: nil, rules: nil,
        roster: CallSpeakerRoster(names: ["Alex Rivera"], selfNames: []),
        rosterFromParticipantList: true, observations: []),
      meeting: record.id)
    harness.coordinator.launch()
    await MeetingCoordinatorTests.eventually("listed") {
      harness.coordinator.record(id: record.id) != nil
    }
    let release = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    MeetingFileWriter.queue.async {
      entered.signal()
      // deadline-fallback: bound a missing release; a timeout fails the test below.
      _ = release.wait(timeout: .now() + 10)
    }
    // settle: deadline fallback around the gate's own `entered` signal.
    let held = await Task.detached { Self.waitBlocking(entered) == .success }.value
    try #require(held, "the file queue was never held")
    // The read passes its first check and waits on the held queue.
    let read = Task { await harness.coordinator.callSpeakerRoster(meetingID: record.id) }
    await Task.yield()
    let deletion = Task { await harness.coordinator.delete(meetingID: record.id) }
    // The test holds the file queue, so this wait must not drain it.
    await MeetingCoordinatorTests.eventually("deletion started", drainFiles: false) {
      harness.coordinator.isDeletingForTesting(record.id)
    }
    release.signal()
    #expect(await read.value == nil, "names never arrive once a deletion has begun")
    _ = await deletion.value
  }
  #endif
}
