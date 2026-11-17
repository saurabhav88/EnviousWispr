import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

/// #4611: when these fail, the out-of-date summary notice names the wrong change (it says
/// "you added notes" after a Transcribe again), or Dismiss does not hide it, or a newer change
/// after Dismiss leaves it hidden.
@Suite("Meeting summary stale notice", .tags(.productOutcome))
struct MeetingSummaryStaleNoticeTests {
  static let written = SummaryInputs(
    transcriptSHA256: "t1", notesRevision: 1, speakerNamesSHA256: "n1", promptVersion: 3,
    providerID: "openAI", configurationSHA256: "c1", transcriptAttemptID: nil,
    contextSHA256: "f1")

  @Test func namesTheOneThingThatChanged() {
    var notes = Self.written
    notes.notesRevision = 2
    var attempt = Self.written
    attempt.transcriptAttemptID = UUID()
    var names = Self.written
    names.speakerNamesSHA256 = "n2"
    var facts = Self.written
    facts.contextSHA256 = "f2"
    var model = Self.written
    model.configurationSHA256 = "c2"
    var both = notes
    both.speakerNamesSHA256 = "n2"
    let cause = MeetingSummaryOwner.staleCause
    #expect(cause(Self.written, notes, false) == .notes)
    #expect(cause(Self.written, Self.written, true) == .notes)
    #expect(cause(Self.written, attempt, false) == .transcript)
    #expect(cause(Self.written, names, false) == .speakerNames)
    // A rename also changes the transcript text's hash (the text carries the names).
    var renamed = names
    renamed.transcriptSHA256 = "t2"
    #expect(cause(Self.written, renamed, false) == .speakerNames)
    #expect(cause(Self.written, facts, false) == .meetingDetails)
    #expect(cause(Self.written, model, false) == .summarySetup)
    #expect(cause(Self.written, both, false) == .several)
    #expect(cause(Self.written, nil, false) == .several)
  }

  @Test func dismissHidesUntilTheNextChange() {
    var now = Self.written
    now.notesRevision = 2
    let shows = MeetingSummaryOwner.noticeShows
    #expect(shows(now, nil, false))
    #expect(!shows(now, now, false))
    #expect(shows(now, now, true))
    var later = now
    later.notesRevision = 3
    #expect(shows(later, now, false))
    #expect(shows(nil, now, false))
  }
}
