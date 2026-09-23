import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// Which text Paste Last Dictation and Copy Last Dictation reuse (#3106).
///
/// When one of these fails, the user gets the wrong words at their cursor: an imported file's
/// transcript, a take they cancelled, a blank paste, or a row they deleted a moment ago.
@MainActor
/// Class: `.productOutcome`: which of the user's dictations gets pasted or copied again.
@Suite("Last dictation reuse: which row is offered (#3106)", .tags(.productOutcome))
struct LastDictationSelectionTests {

  // MARK: Fixtures

  private func makeCoordinator() -> TranscriptCoordinator {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-3106-reuse-\(UUID().uuidString)", isDirectory: true)
    return TranscriptCoordinator(store: TranscriptStore(directory: dir))
  }

  private func dictation(_ text: String, polished: String? = nil, ageSeconds: TimeInterval)
    -> Transcript
  {
    Transcript(
      text: text, polishedText: polished, createdAt: Date().addingTimeInterval(-ageSeconds))
  }

  private func imported(_ text: String, ageSeconds: TimeInterval) -> Transcript {
    Transcript(
      text: text, language: "en", duration: 61, backendType: .parakeet,
      createdAt: Date().addingTimeInterval(-ageSeconds), importedFileName: "interview.m4a")
  }

  /// A cancelled take still inside its retention window: listed in History, never delivered.
  private func held(_ text: String, ageSeconds: TimeInterval) -> Transcript {
    Transcript(
      text: text, createdAt: Date().addingTimeInterval(-ageSeconds),
      escapeRecoveredAt: Date().addingTimeInterval(-60),
      escapeRecoveryTakeID: "take-\(text)")
  }

  // MARK: Which row

  @Test("The newest delivered dictation wins over newer imports, held takes and blank rows")
  func skipsIneligibleNewerRows() {
    let coordinator = makeCoordinator()
    let target = dictation(
      "send the draft to maya tomorrow morning",
      polished: "Send the draft to Maya tomorrow morning.", ageSeconds: 50)
    let older = dictation("an older dictation", ageSeconds: 90)
    coordinator.setTranscriptsForTesting([
      held("cancelled take", ageSeconds: 10),
      imported("a file transcript", ageSeconds: 20),
      dictation("  \n\t ", ageSeconds: 30),
      target,
      older,
    ])

    let offered = coordinator.lastPasteableDictation()
    #expect(offered?.id == target.id)
    // The polished words, which is what the user received.
    #expect(offered?.text == "Send the draft to Maya tomorrow morning.")
    #expect(
      coordinator.lastDictationTextForReuse(id: target.id)
        == "Send the draft to Maya tomorrow morning.")
  }

  @Test("History's filter and search do not change which dictation is reused")
  func ignoresHistoryFilterAndSearch() {
    let coordinator = makeCoordinator()
    let target = dictation("reply to the thread", ageSeconds: 10)
    coordinator.setTranscriptsForTesting([target, imported("a file transcript", ageSeconds: 20)])

    coordinator.historyFilter = .transcripts
    coordinator.searchQuery = "no row contains this"
    #expect(coordinator.filteredTranscripts.isEmpty, "precondition: History lists nothing")

    #expect(coordinator.lastPasteableDictation()?.id == target.id)
    #expect(coordinator.lastDictationTextForReuse(id: target.id) == "reply to the thread")
  }

  @Test("With no eligible row nothing is offered, and none of those rows can be reused by id")
  func nothingEligible() {
    let coordinator = makeCoordinator()
    let rows = [
      held("cancelled take", ageSeconds: 10),
      imported("a file transcript", ageSeconds: 20),
      dictation("", ageSeconds: 30),
    ]
    coordinator.setTranscriptsForTesting(rows)

    #expect(coordinator.lastPasteableDictation() == nil)
    for row in rows {
      #expect(coordinator.lastDictationTextForReuse(id: row.id) == nil)
    }
    #expect(coordinator.lastDictationTextForReuse(id: UUID()) == nil, "an unknown id")
  }

  // MARK: Re-read at action time

  @Test("Acting re-reads the row: an edit is picked up, a deletion or a blanked row is refused")
  func reReadsTheRowById() throws {
    let coordinator = makeCoordinator()
    let first = dictation("first words", ageSeconds: 10)
    try coordinator.saveAndShow(first)
    let offered = try #require(coordinator.lastPasteableDictation())
    #expect(offered.text == "first words")

    // The row changed after the menu rendered; reuse carries the current text, not the snapshot.
    let edited = Transcript(
      id: first.id, text: first.text, polishedText: "First words, polished.",
      createdAt: first.createdAt)
    #expect(try coordinator.updateExistingRow(edited))
    #expect(coordinator.lastDictationTextForReuse(id: offered.id) == "First words, polished.")

    // A row that became blank is no longer reusable, even though its id still exists.
    let blanked = Transcript(
      id: first.id, text: first.text, polishedText: " ", createdAt: first.createdAt)
    #expect(try coordinator.updateExistingRow(blanked))
    #expect(coordinator.lastDictationTextForReuse(id: offered.id) == nil)

    // Deleted between render and click: inert.
    coordinator.delete(blanked)
    #expect(coordinator.lastDictationTextForReuse(id: offered.id) == nil)
    #expect(coordinator.lastPasteableDictation() == nil)
  }
}
