import Testing

@testable import EnviousWisprAppKit

/// #3142: History copy that is localized where it is authored keeps its English bytes,
/// checked against independent literals.
@Suite("History copy", .tags(.productOutcome))
struct HistoryCopyTests {
  @Test("the History filter reads All, Dictations and Transcripts")
  func filterTitles() {
    #expect(HistoryFilter.all.title == "All")
    #expect(HistoryFilter.dictations.title == "Dictations")
    #expect(HistoryFilter.transcripts.title == "Transcripts")
  }

  @Test("both speaker-rename failures keep their English")
  func renameFailureMessages() {
    #expect(RenameFailure.couldNotSaveName == "Couldn't save the name.")
    #expect(RenameFailure.recordingRemoved == "This recording was removed from History.")
  }
}
