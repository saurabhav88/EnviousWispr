import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// History's per-entry commands (#3147 PR2): Restore original text / Use polished text with
/// Undo, and deletions that return what their owner actually did.
@MainActor
/// Class: `.productOutcome` — the text a History card keeps after the user's choice, and what a
/// deletion tells the user about each selected entry.
@Suite("History commands: preferred text and deletion outcomes (#3147)", .tags(.productOutcome))
struct HistoryCommandsTests {

  private func makeCoordinator() -> (TranscriptCoordinator, TranscriptStore) {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-3147-commands-\(UUID().uuidString)", isDirectory: true)
    let store = TranscriptStore(directory: dir)
    return (TranscriptCoordinator(store: store), store)
  }

  private func dictation() -> Transcript {
    Transcript(text: "um raw words", polishedText: "Raw words.", createdAt: Date())
  }

  @Test("Restore original text saves only the preference; Undo puts polished back")
  func restoreAndUndo() async throws {
    let (coordinator, store) = makeCoordinator()
    let row = dictation()
    try await coordinator.saveAndShow(row)

    let change = try #require(
      try await coordinator.setHistoryPreferredVersion(.original, for: row.id))
    #expect(change == HistoryPreferenceChange(rowID: row.id, before: nil, after: .original))
    let saved = try #require(coordinator.currentRow(id: row.id))
    #expect(saved.historyText == "um raw words")
    #expect(saved.polishedText == "Raw words.")
    #expect(try await store.loadAll().first { $0.id == row.id }?.preferredVersion == .original)

    #expect(try await coordinator.undoHistoryPreference(change))
    #expect(coordinator.currentRow(id: row.id)?.preferredVersion == nil)
    #expect(coordinator.currentRow(id: row.id)?.historyText == "Raw words.")
  }

  @Test("Undo never overwrites a later different choice")
  func undoRespectsLaterChoice() async throws {
    let (coordinator, _) = makeCoordinator()
    let row = dictation()
    try await coordinator.saveAndShow(row)
    let first = try #require(
      try await coordinator.setHistoryPreferredVersion(.original, for: row.id))
    _ = try await coordinator.setHistoryPreferredVersion(.polished, for: row.id)

    #expect(try await coordinator.undoHistoryPreference(first) == false)
    #expect(coordinator.currentRow(id: row.id)?.preferredVersion == .polished)
  }

  @Test("imports, meetings, held rows and deleted rows take no preference")
  func preferenceRefusedOutsideDictations() async throws {
    let (coordinator, _) = makeCoordinator()
    let imported = Transcript(text: "raw", importedFileName: "a.m4a")
    let meeting = Transcript(text: "raw", meetingID: UUID())
    let held = Transcript(
      text: "raw", escapeRecoveredAt: Date(), escapeRecoveryTakeID: "take")
    for row in [imported, meeting, held] { try await coordinator.saveAndShow(row) }

    for row in [imported, meeting, held] {
      #expect(try await coordinator.setHistoryPreferredVersion(.original, for: row.id) == nil)
    }
    #expect(try await coordinator.setHistoryPreferredVersion(.original, for: UUID()) == nil)
  }

  @Test("Copy Last and Paste Last keep the polished text after Restore original text")
  func lastDictationKeepsDisplayText() async throws {
    let (coordinator, _) = makeCoordinator()
    let row = dictation()
    try await coordinator.saveAndShow(row)
    _ = try await coordinator.setHistoryPreferredVersion(.original, for: row.id)

    #expect(coordinator.lastPasteableDictation()?.text == "Raw words.")
    #expect(coordinator.lastDictationTextForReuse(id: row.id) == "Raw words.")
    #expect(coordinator.textForDelivery(row) == "um raw words")
  }

  @Test("deleting a dictation reports removed, then already absent")
  func deleteDictationOutcomes() async throws {
    let (coordinator, _) = makeCoordinator()
    let row = dictation()
    try await coordinator.saveAndShow(row)
    var announced: [UUID] = []
    coordinator.onRowDeleted = { announced.append($0) }

    #expect(
      await coordinator.deleteHistoryItem(id: .transcript(row.id), kind: .textAndRecordings)
        == .removed)
    #expect(coordinator.currentRow(id: row.id) == nil)
    #expect(announced == [row.id])
    #expect(
      await coordinator.deleteHistoryItem(id: .transcript(row.id), kind: .textAndRecordings)
        == .alreadyAbsent)
  }

  @Test("an import has no recording to delete: skipped, and its text stays")
  func importRecordingDeleteIsSkipped() async throws {
    let (coordinator, _) = makeCoordinator()
    let imported = Transcript(text: "raw", importedFileName: "a.m4a")
    try await coordinator.saveAndShow(imported)
    #expect(
      await coordinator.deleteHistoryItem(id: .transcript(imported.id), kind: .recordingsOnly)
        == .skipped)
    #expect(coordinator.currentRow(id: imported.id) != nil)
  }

  @Test("a meeting deletion returns EnviousMeet's real outcome, for the meeting and its row")
  func meetingOutcomesComeFromTheOwner() async throws {
    let (coordinator, _) = makeCoordinator()
    let meetingID = UUID()
    let row = Transcript(text: "a meeting", meetingID: meetingID)
    try await coordinator.saveAndShow(row)
    var asked: [UUID] = []
    coordinator.deleteMeeting = {
      asked.append($0)
      return false
    }
    coordinator.deleteMeetingAudio = { _ in .skipped }

    #expect(
      await coordinator.deleteHistoryItem(id: .meeting(meetingID), kind: .textAndRecordings)
        == .failed)
    #expect(
      await coordinator.deleteHistoryItem(id: .transcript(row.id), kind: .textAndRecordings)
        == .failed)
    #expect(asked == [meetingID, meetingID])
    #expect(
      await coordinator.deleteHistoryItem(id: .meeting(meetingID), kind: .recordingsOnly)
        == .skipped)
    #expect(coordinator.currentRow(id: row.id) != nil)
  }
}
