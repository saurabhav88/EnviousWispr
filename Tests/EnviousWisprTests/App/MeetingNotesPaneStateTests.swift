import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4724: when this fails, a History meeting page forgets that the user chose AI summary and
/// opens Your notes on the next meeting, or opens a notes-only meeting on an AI summary it lacks.
@MainActor
@Suite("Meeting page remembers the chosen tab", .tags(.productOutcome))
struct MeetingNotesPaneStateTests {
  @Test(
    "a chosen tab opens the next meeting; a notes-only meeting and a shown note keep Your notes")
  func remembersTheChosenTab() {
    let remembered = RememberedMeetingPane()
    let first = MeetingNotesPaneState(remembered: remembered)
    #expect(first.leftPane == .notes)

    first.chooseLeftPane(.summary)
    first.openMeeting(notesOnly: false)
    #expect(first.leftPane == .summary, "the next meeting on the same page")
    #expect(MeetingNotesPaneState(remembered: remembered).leftPane == .summary, "a new page")

    first.openMeeting(notesOnly: true)
    #expect(first.leftPane == .notes)
    first.openMeeting(notesOnly: false)
    #expect(first.leftPane == .summary, "a notes-only meeting does not change the choice")

    first.showNote(UUID())
    #expect(first.leftPane == .notes)
    first.openMeeting(notesOnly: false)
    #expect(first.leftPane == .summary, "showing a note is not a tab choice")

    first.chooseLeftPane(.notes)
    #expect(MeetingNotesPaneState(remembered: remembered).leftPane == .notes)
  }
}
