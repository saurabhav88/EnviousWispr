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

  private func height(_ status: DictationRecordingStatus?) -> CGFloat {
    let view = NSHostingView(
      rootView: HistoryDictationRecordingSlot(status: status, player: nil).frame(width: 520))
    return view.fittingSize.height
  }

  @Test("The recording line takes the same height before and after its status arrives")
  func recordingSlotHeightIsFixed() {
    let before = height(nil)
    #expect(before > 0)
    let after = [
      height(.unreadable), height(.absent(nil)), height(.absent(RecordedAbsence(.recordingsOff))),
      height(.absent(RecordedAbsence(.expired, expiredAfterDays: 7))),
    ]
    #expect(after.allSatisfy { $0 == before }, "status nil \(before) vs \(after)")
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
    coordinator.startHistoryCatalog()
    await session.waitForIndexingForTesting()

    // Nothing hydrated this row: the card drew from catalog display data.
    #expect(coordinator.dictationTextForDelivery(id: row.id) == "an older dictation")
    // Another process deletes it: the press delivers nothing.
    try TranscriptStore(directory: directory).delete(id: row.id)
    #expect(coordinator.dictationTextForDelivery(id: row.id) == nil)
  }
}
