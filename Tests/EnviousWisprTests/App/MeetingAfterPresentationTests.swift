import CoreGraphics
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

/// #3147 PR4A: when these fail, a Meetings card hides a meeting's state or its failure reason,
/// shows a transcript or summary it should not, a rename looks saved when it was not (or loses
/// what the user typed), note markers sit at the wrong time or swallow each other, a speaker is
/// given a guessed name or a wrong talk share, playback highlights the wrong turn, or View
/// source leads somewhere the validator did not accept.
@Suite("Meeting cards and after view", .tags(.productOutcome))
struct MeetingAfterPresentationTests {
  typealias P = MeetingAfterPresentation

  static func record(
    _ state: MeetingState, title: String? = nil, audioKept: Bool = true,
    failure: String? = nil, committed: Bool = false
  ) -> MeetingRecord {
    var record = MeetingRecord(engine: .parakeet, trackStatus: [.microphone: .captured])
    record.state = state
    record.title = title
    record.audioKept = audioKept
    record.failureCode = failure
    if committed { record.committedTranscriptAttemptID = UUID() }
    record.segments = [
      .microphone: [
        MeetingSegmentInfo(index: 0, fileName: "a.caf", startMs: 0, frameCount: 960_000)
      ]
    ]
    return record
  }

  static func row(meetingID: UUID) -> Transcript {
    Transcript(
      text: "Hello there.", backendType: .parakeet, speakerAnalysis: .labeled(count: 2),
      speakerNames: ["sys:1": "Ana"], turns: [], meetingID: meetingID)
  }

  // MARK: - Card states

  @Test("every legacy row state keeps its own status and line")
  func cardStates() {
    let cases: [(MeetingState, String?, MeetingsPresentation.Status)] = [
      (.recording, nil, .recording),
      (.stopping, nil, .saving),
      (.queued, nil, .waiting),
      (.interrupted, nil, .interrupted),
      (.processing, nil, .needsAttention),
      (.failed, "no_audio", .needsAttention),
      (.notesOnly, nil, .notesOnly),
    ]
    for (state, failure, status) in cases {
      let card = P.card(P.CardInputs(record: Self.record(state, failure: failure)))
      #expect(card.status?.label == MeetingsPresentation.statusLabel(status), "\(state)")
      guard case .status(let text, _) = card.line else {
        Issue.record("\(state) shows no status line: \(card.line)")
        continue
      }
      #expect(text.isEmpty == false, "\(state)")
    }
    let failed = P.card(P.CardInputs(record: Self.record(.failed, failure: "no_audio")))
    #expect(
      failed.line
        == .status(
          MeetingsPresentation.failureLine(Self.record(.failed, failure: "no_audio"))!, .error))
    #expect(failed.status?.tone == .error)
  }

  @Test("a queued meeting waiting for disk space says so, as an error")
  func waitingForSpace() {
    let card = P.card(
      P.CardInputs(record: Self.record(.queued), queueWaitsForSpace: true))
    #expect(card.line == .status(P.waitingForSpaceLine, .error))
    #expect(card.status?.tone == .error)
  }

  @Test("the pass that owns a meeting shows Transcribing, even over a failed state")
  func transcribing() {
    let record = Self.record(.processing)
    let card = P.card(P.CardInputs(record: record, processingID: record.id))
    #expect(card.status?.label == MeetingsPresentation.statusLabel(.transcribing))
    #expect(card.line == .status(P.transcribingLine, .busy))
  }

  @Test("a committed transcript keeps its preview while Transcribe again runs")
  func retainedPreview() {
    let record = Self.record(.processing, committed: true)
    let card = P.card(
      P.CardInputs(
        record: record, row: Self.row(meetingID: record.id), processingID: record.id,
        previewText: "Ana: Hello there."))
    #expect(card.line == .preview("Ana: Hello there."))
    #expect(card.status?.label == MeetingsPresentation.statusLabel(.transcribing))
    #expect(card.speakers == MeetingsPresentation.speakers(.labeled(count: 2)))
  }

  @Test("ready: the summary's first line wins over the transcript; no summary says so")
  func readyLines() {
    let record = Self.record(.ready, title: "Weekly sync")
    let row = Self.row(meetingID: record.id)
    let withSummary = P.card(
      P.CardInputs(
        record: record, row: row, previewText: "Ana: Hello there.",
        summary: "## Decisions\n- **Ship** on Friday.\n- Second.", summaryProviderID: "egOne"))
    #expect(withSummary.status == nil)
    #expect(withSummary.line == .summary("Ship on Friday."))
    #expect(withSummary.footer.contains(P.summaryByLine(LLMProvider.egOne.displayName)))
    #expect(withSummary.title == "Weekly sync")
    #expect(withSummary.isUntitled == false)

    let bare = P.card(P.CardInputs(record: record, row: row, previewText: "Ana: Hello there."))
    #expect(bare.line == .preview("Ana: Hello there."))
    #expect(bare.footer.contains(P.noSummaryLine))
  }

  @Test("a ready meeting whose row is not listed says it is unavailable, never blank")
  func readyWithoutRow() {
    let card = P.card(P.CardInputs(record: Self.record(.ready)))
    #expect(card.line == .status(MeetingHistoryPresentation.unavailableMessage, .neutral))
    #expect(card.isUntitled)
    #expect(card.title == MeetingsPresentation.title(Self.record(.ready)))
  }

  @Test("an unpublished summary is not shown before the transcript is committed")
  func summaryNeedsCommittedRow() {
    let record = Self.record(.queued)
    let card = P.card(
      P.CardInputs(record: record, row: Self.row(meetingID: record.id), summary: "Old"))
    #expect(card.line == .status(P.waitingLine, .neutral))
  }

  @Test("a deleted recording is named; a notes-only meeting never says audio went")
  func audioLines() {
    #expect(
      P.card(P.CardInputs(record: Self.record(.ready, audioKept: false))).audioLine
        == P.recordingDeletedLine)
    #expect(
      P.card(P.CardInputs(record: Self.record(.failed, audioKept: false))).audioLine
        == P.recordingDeletedNoTranscriptLine)
    #expect(
      P.card(P.CardInputs(record: Self.record(.notesOnly, audioKept: false))).audioLine == nil)
    #expect(P.card(P.CardInputs(record: Self.record(.ready))).audioLine == nil)
  }

  @Test("a row whose meeting folder is gone shows its own preview and cannot be renamed")
  func orphan() {
    let meetingID = UUID()
    let card = P.card(
      P.CardInputs(record: nil, row: Self.row(meetingID: meetingID), previewText: "Hi"))
    #expect(card.line == .preview("Hi"))
    #expect(card.title == P.fallbackTitle)
    #expect(card.canRename == false)
  }

  @Test("a meeting being deleted, or saved by a newer build, offers no rename")
  func renameAvailability() {
    var deleting = Self.record(.ready)
    deleting.deletionRequested = true
    #expect(P.card(P.CardInputs(record: deleting)).canRename == false)
    #expect(P.card(P.CardInputs(record: Self.record(.ready))).canRename)
  }

  @Test("the summary's first readable line skips headings and list and emphasis marks")
  func summaryFirstLine() {
    #expect(P.summaryFirstLine("# Title\n\n- [ ] **Send** the brief") == "Send the brief")
    #expect(P.summaryFirstLine("> Quoted") == "Quoted")
    #expect(P.summaryFirstLine("## Only a heading\n\n") == nil)
    #expect(P.summaryFirstLine("Plain sentence.\nSecond.") == "Plain sentence.")
  }

  // MARK: - Inline title

  @Test("Return with the same name writes nothing and closes")
  func titleUnchanged() {
    var edit = P.TitleEdit()
    edit.begin(storedTitle: "Sync")
    #expect(edit.draft == "Sync")
    edit.draft = "  Sync "
    #expect(edit.commit(storedTitle: "Sync") == .unchanged)
    #expect(edit.isEditing == false)
  }

  @Test("an empty name is sent so the coordinator restores the untitled label")
  func titleEmpty() {
    var edit = P.TitleEdit()
    edit.begin(storedTitle: "Sync")
    edit.draft = "   "
    #expect(edit.commit(storedTitle: "Sync") == .rename(""))
    #expect(edit.phase == .saving)
    edit.finish(saved: true)
    #expect(edit.isEditing == false)
  }

  @Test("an untitled meeting opens an empty field")
  func titleUntitled() {
    var edit = P.TitleEdit()
    edit.begin(storedTitle: nil)
    #expect(edit.draft.isEmpty)
    #expect(edit.commit(storedTitle: nil) == .unchanged)
  }

  @Test("a failed rename keeps the typed name; Try again sends it again")
  func titleFailure() {
    var edit = P.TitleEdit()
    edit.begin(storedTitle: nil)
    edit.draft = "Board review"
    #expect(edit.commit(storedTitle: nil) == .rename("Board review"))
    #expect(edit.commit(storedTitle: nil) == .busy)
    edit.cancel()
    #expect(edit.phase == .saving, "Escape never drops a rename in flight")
    edit.finish(saved: false)
    #expect(edit.phase == .failed)
    #expect(edit.draft == "Board review")
    #expect(edit.commit(storedTitle: nil) == .rename("Board review"))
    edit.finish(saved: true)
    #expect(edit.isEditing == false)
  }

  @Test("Escape closes the field without writing")
  func titleCancel() {
    var edit = P.TitleEdit()
    edit.begin(storedTitle: "Sync")
    edit.draft = "Other"
    edit.cancel()
    #expect(edit.isEditing == false)
    #expect(edit.commit(storedTitle: "Sync") == .unchanged)
  }

  // MARK: - Markers

  static func block(_ ms: Int?, _ text: String = "note") -> MeetingNoteBlock {
    MeetingNoteBlock(startedAtMs: ms, text: text)
  }

  @Test("only timed, non-empty notes inside the recording become markers, in time order")
  func markers() {
    let document = MeetingNotesDocument(blocks: [
      Self.block(30_000, "later"), Self.block(nil, "migrated"), Self.block(10_000, "first"),
      Self.block(20_000, "   "), Self.block(70_000, "past the end"), Self.block(60_000, "at end"),
    ])
    let markers = P.noteMarkers(document, durationMs: 60_000)
    #expect(markers.map(\.text) == ["first", "later", "at end"])
    #expect(P.noteMarkers(document, durationMs: 0).isEmpty)
  }

  @Test("markers closer than the gap merge into one cluster; just apart stay separate")
  func clusters() {
    // 1 000 pt track over 100 s: 10 pt per second; the gap is 18 pt (1.8 s).
    let near = [
      P.NoteMarker(id: UUID(), ms: 10_000, kind: .text, text: "a"),
      P.NoteMarker(id: UUID(), ms: 11_700, kind: .text, text: "b"),
      P.NoteMarker(id: UUID(), ms: 11_799, kind: .task, text: "c"),
      P.NoteMarker(id: UUID(), ms: 11_800, kind: .text, text: "d"),
    ]
    let clusters = P.clusters(near, durationMs: 100_000, trackWidth: 1_000)
    #expect(clusters.map(\.markers.count) == [3, 1])
    #expect(clusters[0].ms == 10_000)
    #expect(P.clusterLabel(clusters[0]) == "3 notes")
    #expect(P.clusterLabel(clusters[1]) == "1 note")
    #expect(P.clusters(near, durationMs: 100_000, trackWidth: 0).isEmpty)
  }

  // MARK: - Participants

  static func turn(_ id: String, _ speaker: String, _ start: Int?, _ end: Int?) -> Turn {
    Turn(
      id: id, speakerId: speaker, startMs: start, endMs: end, originalTextRange: 0..<1,
      wasPolished: false)
  }

  @Test("talk share comes from measured turn time; unnamed and unknown speakers are labelled")
  func participants() {
    let turns = [
      Self.turn("t1", "mic:you", 0, 30_000),
      Self.turn("t2", "sys:1", 30_000, 40_000),
      Self.turn("t3", "sys:2", 40_000, 50_000),
      Self.turn("t4", TurnAssembler.unknownSpeakerID, 50_000, 60_000),
      Self.turn("t5", "sys:1", nil, nil),
    ]
    let people = P.participants(turns: turns, speakerNames: ["mic:you": "You", "sys:1": "Ana"])
    #expect(people.map(\.name) == ["You", "Ana", P.unnamedSpeakerLabel, P.unknownSpeakerLabel])
    #expect(people.map(\.isNamed) == [true, true, false, false])
    #expect(people[0].share == 0.5)
    #expect(people[1].spokenMs == 10_000)
    #expect(P.participants(turns: [Self.turn("x", "a", nil, 5)], speakerNames: [:]).isEmpty)
  }

  // MARK: - Follow playback

  @Test("playback is in the last turn that started at or before the position")
  func activeTurn() {
    let turns = [
      Self.turn("a", "s", 1_000, 2_000), Self.turn("b", "s", nil, nil),
      Self.turn("c", "s", 5_000, 6_000),
    ]
    #expect(P.activeTurnID(turns: turns, positionMs: 999) == nil)
    #expect(P.activeTurnID(turns: turns, positionMs: 1_000) == "a")
    #expect(P.activeTurnID(turns: turns, positionMs: 4_999) == "a")
    #expect(P.activeTurnID(turns: turns, positionMs: 5_000) == "c")
  }

  // MARK: - Summary sources

  @Test("View source leads only to a shown turn, else an existing note, else nowhere")
  func sourceTarget() {
    let note = UUID()
    let sources: [MeetingSummarySource] = [
      .turn(id: "hidden-echo", textSHA256: "x"), .note(blockID: note, textSHA256: "y"),
      .turn(id: "t2", textSHA256: "z"),
    ]
    #expect(
      P.sourceTarget(sources, visibleTurnIDs: ["t2"], noteBlockIDs: [note]) == .turn("t2"))
    #expect(P.sourceTarget(sources, visibleTurnIDs: [], noteBlockIDs: [note]) == .note(note))
    #expect(P.sourceTarget(sources, visibleTurnIDs: [], noteBlockIDs: []) == nil)
    #expect(P.isFromNotes([.note(blockID: note, textSHA256: "y")]))
    #expect(P.isFromNotes(sources) == false)
    #expect(P.isFromNotes([]) == false)
  }

  // MARK: - Layout, dock and status

  @Test("the panes stack below 800 points and sit side by side from 800")
  func layout() {
    #expect(P.stacksPanes(width: 799))
    #expect(P.stacksPanes(width: 800) == false)
  }

  @Test("the dock says why nothing plays")
  func dockAbsence() {
    #expect(P.dockAbsence(nil) == .unavailable)
    #expect(P.dockAbsence(Self.record(.notesOnly, audioKept: false)) == .nothingRecorded)
    #expect(P.dockAbsence(Self.record(.ready, audioKept: false)) == .recordingDeleted)
    #expect(P.dockAbsence(Self.record(.processing)) == .notReadyYet)
  }

  @Test("the status strip follows the transcript, then the summary")
  func strip() {
    let ready = Self.record(.ready)
    #expect(
      P.strip(
        record: ready, processing: true, queueWaitsForSpace: false, writingSummary: false,
        hasSummary: false) == .finishingTranscript)
    #expect(
      P.strip(
        record: Self.record(.queued), processing: false, queueWaitsForSpace: true,
        writingSummary: false, hasSummary: false) == .waitingForSpace)
    #expect(
      P.strip(
        record: ready, processing: false, queueWaitsForSpace: false, writingSummary: true,
        hasSummary: false) == .writingSummary)
    #expect(
      P.strip(
        record: ready, processing: false, queueWaitsForSpace: false, writingSummary: false,
        hasSummary: true) == .summaryReady)
    #expect(
      P.strip(
        record: Self.record(.failed), processing: false, queueWaitsForSpace: false,
        writingSummary: false, hasSummary: true) == .none)
  }
}
