import AppKit
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// #4609: History scrolling kept moving after the gesture and landed short because dictation
/// cards resized when file reads finished. These tests guard what the user feels: a card is
/// complete and keeps its height from first display, and its actions still deliver the live row.
@MainActor
@Suite(
  "History dictation cards keep their height and still deliver the live row", .tags(.productOutcome)
)
struct HistoryCardStabilityTests {
  init() { _ = NSApplication.shared }

  @Test("A card knows a dictation has no recording before its own status read (#4611)")
  func recordingPresenceIsKnownBeforeTheCardReads() {
    let changes = DictationRecordingChanges()
    let kept = UUID()
    let none = UUID()
    #expect(changes.hasRecording(none) == nil)
    changes.noteIndex([kept])
    #expect(changes.hasRecording(kept) == true)
    #expect(changes.hasRecording(none) == false)
    // A new recording published for a row: unknown until that card reads it again.
    changes.changed(none)
    #expect(changes.hasRecording(none) == nil)
    changes.note(none, hasRecording: true)
    #expect(changes.hasRecording(none) == true)
  }

  @Test("The catalog carries a dictation's full drawn content, past the 600-character preview")
  func projectionCarriesTheWholeCard() throws {
    let long = String(repeating: "spoken words ", count: 120)  // 1,560 characters
    let row = Transcript(
      text: long, polishedText: long.uppercased(), language: "en", backendType: .parakeet,
      createdAt: Date(timeIntervalSinceReferenceDate: 750_000_000), llmProvider: "openai",
      llmModel: "model-x")
    let summary = HistoryCatalog.Summary(
      key: .init(tab: .dictations, id: row.id), date: row.createdAt,
      preview: String(row.historyText.prefix(600)),
      sources: [], rowID: row.id, backendName: row.backendType.displayName,
      polishModel: row.llmModel,
      wasPolished: true, recovered: row.isRecovered, interrupted: row.inputDeviceWasRemoved,
      dictation: HistoryDictationDisplay.catalogData(of: row))
    // The catalog stores the summary as JSON.
    let stored = try JSONDecoder().decode(
      HistoryCatalog.Summary.self, from: JSONEncoder().encode(summary))
    let fromCatalog = try #require(HistoryDictationDisplay(stored))
    #expect(fromCatalog == HistoryDictationDisplay(row))
    #expect(fromCatalog.displayText.count == long.count)
  }

  @Test("A card's Copy reads the live row from disk, even when no payload was ever loaded")
  func deliveryReadsTheLiveRow() async throws {
    let root = TestTemporaryDirectory.url.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let changes = HistorySourceChanges()
    let directory = root.appendingPathComponent("transcripts")
    let store = TranscriptStore(directory: directory, historyChanges: changes)
    let meetings = MeetingStore(
      root: root.appendingPathComponent("Meetings"), historyChanges: changes)
    let row = Transcript(text: "an older dictation", processingTime: 0, backendType: .parakeet)
    try store.save(row)
    let session = HistoryCatalogSession(
      changes: changes, sources: store.historyCatalogSources(meetings: meetings),
      directory: root.appendingPathComponent("catalog"))
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.catalogSession = session
    // The session alone, without the latest-dictation hydration startHistoryCatalog installs.
    session.start()
    await session.waitForIndexingForTesting()
    try #require(coordinator.currentRow(id: row.id) == nil)

    // Nothing hydrated this row: the card drew from catalog display data.
    #expect(coordinator.dictationTextForDelivery(id: row.id) == "an older dictation")
    // Edited on disk after the card drew: the press delivers the edited text.
    let edited = Transcript(id: row.id, text: "edited after display", processingTime: 0, backendType: .parakeet)
    try store.save(edited)
    #expect(coordinator.dictationTextForDelivery(id: row.id) == edited.historyText)
    // Another process deletes it: the press delivers nothing.
    try TranscriptStore(directory: directory).delete(id: row.id)
    #expect(coordinator.dictationTextForDelivery(id: row.id) == nil)
  }
}
