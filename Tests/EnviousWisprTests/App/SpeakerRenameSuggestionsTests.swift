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

  @Test("arrow keys move the highlight by name; typing clears it, so Return saves what was typed")
  func keyboardHighlight() {
    let names = ["Alex Rivera", "Priya Shah", "Dana Lee"]
    var highlight = RenameSuggestionHighlight()
    let upFirst = highlight.up(in: names)
    #expect(upFirst == false, "Up with nothing highlighted is left to the field")
    let downFirst = highlight.down(in: names)
    #expect(downFirst)
    #expect(highlight.choice(in: names) == "Alex Rivera")
    _ = highlight.down(in: names)
    _ = highlight.down(in: names)
    _ = highlight.down(in: names)
    #expect(highlight.choice(in: names) == "Dana Lee", "Down stops on the last name")
    _ = highlight.up(in: names)
    #expect(highlight.choice(in: names) == "Priya Shah")
    // Open, Down, then type a name: Return must save the typed name.
    highlight.fieldEdited()
    #expect(highlight.choice(in: names) == nil)
    _ = highlight.down(in: names)
    let upFromFirst = highlight.up(in: names)
    #expect(upFromFirst)
    #expect(highlight.choice(in: names) == nil, "Up from the first clears the highlight")
    let downInEmpty = highlight.down(in: [])
    #expect(downInEmpty == false)
  }

  @Test("a highlighted name that leaves the list is not replaced by its neighbour")
  func highlightSurvivesListChange() {
    var highlight = RenameSuggestionHighlight()
    _ = highlight.down(in: ["Alex Rivera", "Priya Shah"])
    _ = highlight.down(in: ["Alex Rivera", "Priya Shah"])
    highlight.listChanged(to: ["Priya Shah", "Dana Lee"])
    #expect(highlight.choice(in: ["Priya Shah", "Dana Lee"]) == "Priya Shah", "kept: still listed")
    highlight.listChanged(to: ["Alex Rivera", "Dana Lee"])
    #expect(highlight.name == nil)
    #expect(highlight.choice(in: ["Alex Rivera", "Dana Lee"]) == nil)
  }

  @Test("a roster read is shown only for the request it answered")
  func keyedRead() {
    let roster = CallSpeakerRoster(names: ["Ana"], selfNames: [])
    let log = CallSpeakerLog(
      surface: .zoomApp, source: .app, status: .observed, lag: nil, rules: nil, roster: roster,
      rosterFromParticipantList: true, observations: [])
    let read = KeyedRosterRead(key: "meeting-A", evidence: CallSpeakerEvidence(log))
    #expect(read.roster(for: "meeting-A") == roster)
    #expect(read.roster(for: "meeting-B") == nil, "a switch to another meeting hides it")
    #expect(read.roster(for: nil) == nil)
  }

  @Test("the missing-permission note shows only for a recording that noted it, on its own request")
  func permissionNote() {
    func read(_ status: CallSpeakerObservationStatus?, key: String = "meeting-A")
      -> KeyedRosterRead<String>
    {
      KeyedRosterRead(
        key: key,
        evidence: CallSpeakerEvidence(
          CallSpeakerLog(
            surface: .teamsApp, source: .app, status: status, lag: nil, rules: nil,
            roster: CallSpeakerRoster(names: [], selfNames: []), rosterFromParticipantList: nil,
            observations: [])))
    }
    #expect(read(.noPermission).permissionMissing(for: "meeting-A"))
    #expect(!read(.noPermission).permissionMissing(for: "meeting-B"), "another meeting's read")
    #expect(!read(.noPermission).permissionMissing(for: nil))
    for status: CallSpeakerObservationStatus? in [.observed, .unreadable, .unsupported, nil] {
      #expect(!read(status).permissionMissing(for: "meeting-A"), "\(String(describing: status))")
    }
    // No file, an older file or a damaged one: no evidence, so nothing is said.
    #expect(!KeyedRosterRead<String>(key: "meeting-A", evidence: nil).permissionMissing(for: "meeting-A"))
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
    #expect(await harness.coordinator.callSpeakerEvidence(meetingID: record.id) == CallSpeakerEvidence(log))
    #expect(await harness.coordinator.callSpeakerEvidence(meetingID: other.id) == nil)
    #expect(await harness.coordinator.callSpeakerEvidence(meetingID: UUID()) == nil)
    await harness.coordinator.deleteAudio(meetingID: record.id)
    #expect(await harness.coordinator.callSpeakerEvidence(meetingID: record.id) == nil)
  }

  /// True when `stream` delivers a signal before the deadline.
  static func firstSignal(_ stream: AsyncStream<Void>, within limit: Duration) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await _ in stream { return true }
        return false
      }
      group.addTask {
        try? await Task.sleep(for: limit)  // deadline-fallback: bounds the signal wait above
        return false
      }
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
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
    // The read passes its first check (the coordinator says so) and waits on the held queue;
    // only then does the deletion start.
    let (admissions, admitted) = AsyncStream<Void>.makeStream()
    harness.coordinator.rosterReadAdmittedForTesting = { admitted.yield() }
    defer { harness.coordinator.rosterReadAdmittedForTesting = nil }
    let read = Task { await harness.coordinator.callSpeakerEvidence(meetingID: record.id) }
    try #require(await Self.firstSignal(admissions, within: .seconds(5)), "the read was never admitted")
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
