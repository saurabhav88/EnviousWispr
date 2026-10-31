import Testing

@testable import EnviousWisprAppKit

/// #3142: History copy that is localized where it is authored keeps its English bytes,
/// checked against independent literals.
@Suite("History copy", .tags(.productOutcome))
struct HistoryCopyTests {
  @Test("the History filter reads All, Dictations, Transcripts and Meetings")
  func filterTitles() {
    #expect(HistoryFilter.all.title == "All")
    #expect(HistoryFilter.dictations.title == "Dictations")
    #expect(HistoryFilter.transcripts.title == "Transcripts")
    #expect(HistoryFilter.recordings.title == "Meetings")
  }

  @Test("the History tabs show the letters A, D, T and M, all different")
  func filterLetters() {
    let letters = HistoryFilter.allCases.map(\.shortTitle)
    #expect(letters == ["A", "D", "T", "M"])
    #expect(Set(letters).count == HistoryFilter.allCases.count)
  }

  @Test("both speaker-rename failures keep their English")
  func renameFailureMessages() {
    #expect(RenameFailure.couldNotSaveName == "Couldn't save the name.")
    #expect(RenameFailure.recordingRemoved == "This recording was removed from History.")
  }
}
