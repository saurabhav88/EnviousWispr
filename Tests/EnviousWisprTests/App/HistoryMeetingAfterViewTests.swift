import AppKit
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

/// #3147 PR4A: when these fail, the meeting dock grows past the 88 pt the transcript area is
/// laid out against (the transcript is pushed off screen), the transcript does not redraw when
/// View source or playback moves the highlight (the user loses where they are), or a summary
/// item offers View source the validator never accepted.
@MainActor
@Suite("Meeting after view parts", .tags(.productOutcome))
struct HistoryMeetingAfterViewTests {
  final class Silence: PlaybackWindowAudio, @unchecked Sendable {
    func window(startMs: Int, count: Int) throws -> [Float] {
      [Float](repeating: 0, count: count * 16)
    }
  }

  static func player(durationMs: Int = 90_000) -> MeetingPlaybackController {
    MeetingPlaybackController(
      media: .transcript(Silence()), durationMs: durationMs,
      output: MeetingPlaybackControllerTests.FakeOutput())
  }

  /// The notes owner as the after view consumes it; never a production implementation.
  final class FakeNotes: MeetingNotesAccessing {
    var document = MeetingNotesDocument(blocks: [])
    var revision = 0
    var applied: [MeetingNotesEdit] = []

    func snapshot(for meetingID: UUID) -> MeetingNotesSnapshot {
      MeetingNotesSnapshot(document: document, revision: revision, canEdit: true, saveState: .saved)
    }

    func apply(
      _ edit: MeetingNotesEdit, to meetingID: UUID, expectedRevision: Int, atMs: Int?
    ) -> Bool {
      guard expectedRevision == revision else { return false }
      applied.append(edit)
      revision += 1
      return true
    }

    func flush(_ meetingID: UUID) async -> Bool { true }
  }

  /// The reference owner with a structured summary but no validated source: what an edited,
  /// stale or unqualified summary looks like to the view.
  final class FakeReferences: MeetingSummaryReferencing {
    var summary: MeetingSummaryDocument?
    func document(for meetingID: UUID) -> MeetingSummaryDocument? { summary }
    func validatedSource(for itemID: UUID, meetingID: UUID) -> ValidatedMeetingSummarySource? {
      nil
    }
  }

  @Test("the dock is the mock's 88 points with markers and participants, playing or not")
  func dockHeight() {
    let markers = [
      MeetingAfterPresentation.NoteMarker(id: UUID(), ms: 1_000, kind: .text, text: "a"),
      MeetingAfterPresentation.NoteMarker(id: UUID(), ms: 1_100, kind: .task, text: "b"),
    ]
    let people = [
      MeetingAfterPresentation.Participant(
        id: "mic:you", name: "You", isNamed: true, spokenMs: 1_000, share: 1)
    ]
    for content in [
      MeetingAfterPlayerBar.Content.player(Self.player()),
      .unavailable(.recordingDeleted), .unavailable(.nothingRecorded),
    ] {
      let host = NSHostingView(
        rootView: MeetingAfterPlayerBar(
          content: content, markers: markers, participants: people, onSelectNote: { _ in }
        )
        .frame(width: 750))
      #expect(host.fittingSize.height == MeetingAfterPlayerBar.height)
    }
  }

  @Test("the transcript redraws when the highlight or playback turn moves, and only then")
  func turnListEquality() {
    let turns = [
      Turn(
        id: "t1", speakerId: "mic:you", startMs: 0, endMs: 1_000, originalTextRange: 0..<2,
        wasPolished: false)
    ]
    let player = Self.player()
    func list(highlighted: String? = nil, active: String? = nil, player: MeetingPlaybackController?)
      -> MeetingAfterTurnList
    {
      MeetingAfterTurnList(
        rowID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, turns: turns,
        rawText: "hi", speakerNames: ["mic:you": "You"], player: player,
        renameSuggestions: .none, highlightedTurnID: highlighted, activeTurnID: active)
    }
    #expect(list(player: player) == list(player: player))
    #expect(list(highlighted: "t1", player: player) != list(player: player))
    #expect(list(active: "t1", player: player) != list(player: player))
    #expect(list(player: player) != list(player: Self.player()))
    #expect(list(player: nil) != list(player: player))
  }

  @Test("a summary item with no validated source offers no View source and no notes tag")
  func noGuessedSource() throws {
    let note = MeetingNoteBlock(startedAtMs: 2_000, text: "Send the brief")
    let notes = FakeNotes()
    notes.document = MeetingNotesDocument(blocks: [note])
    let references = FakeReferences()
    let item = MeetingSummaryItem(
      id: UUID(), text: "Send the brief",
      citations: [
        MeetingSummaryCitation(
          source: .note(blockID: note.id, textSHA256: "x"), quote: "Send the brief",
          rangeUTF16: 0..<14)
      ])
    // Candidate citations exist, but only the validator may turn them into a link.
    let sources = references.validatedSource(for: item.id, meetingID: UUID())?.sources ?? []
    #expect(
      MeetingAfterPresentation.sourceTarget(
        sources, visibleTurnIDs: [], noteBlockIDs: [note.id]) == nil)
    #expect(MeetingAfterPresentation.isFromNotes(sources) == false)
    // The note itself still sits on the dock at its time.
    let markers = MeetingAfterPresentation.noteMarkers(
      notes.snapshot(for: UUID()).document, durationMs: 60_000)
    #expect(markers.map(\.id) == [note.id])
  }
}
