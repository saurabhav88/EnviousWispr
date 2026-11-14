import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

@MainActor
@Suite("History catalog opens independently of the old diary reader", .tags(.productOutcome))
struct HistoryCatalogSessionTests {
  @Test("A session pages and selects saved History without fully hydrating it")
  func pagedSession() async throws {
    let root = TestTemporaryDirectory.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let changes = HistorySourceChanges()
    let store = TranscriptStore(directory: root.appendingPathComponent("transcripts"), historyChanges: changes)
    let meetings = MeetingStore(root: root.appendingPathComponent("Meetings"), historyChanges: changes)
    let date = Date(timeIntervalSinceReferenceDate: 750_000_000)
    for _ in 1...40 {
      try store.save(Transcript(text: "budget notes", processingTime: 0, backendType: .parakeet, createdAt: date))
    }
    let session = HistoryCatalogSession(
      changes: changes, sources: store.historyCatalogSources(meetings: meetings),
      directory: root.appendingPathComponent("catalog"))
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.catalogSession = session
    coordinator.startHistoryCatalog()
    await session.waitForIndexingForTesting()

    let key = coordinator.historyQueryKey(for: .dictations, state: coordinator.requestedHistoryState(for: .dictations))
    let first = try #require(await coordinator.historyResults(for: key))
    #expect(first.items.count == 30)
    #expect(first.catalogDayCounts?.values.first == 40)
    let next = try #require(await coordinator.historyResults(for: key, extending: first))
    #expect(next.items.count == 40)
    let matching = try #require(await coordinator.matchingIDs(for: first))
    #expect(Set(matching).count == 40)
    let rowID: UUID
    switch try #require(first.items.first?.id) {
    case .transcript(let id): rowID = id
    case .meeting:
      Issue.record("Dictations returned a meeting")
      return
    }
    let loaded = try #require(await coordinator.loadCatalogDetail(rowID))
    #expect(loaded.text == "budget notes")
    var state = coordinator.requestedHistoryState(for: .dictations)
    let deep = try #require(next.items.last?.id)
    state.scrollAnchorID = deep
    coordinator.setHistoryState(state, for: .dictations)
    let deepKey = coordinator.historyQueryKey(for: .dictations, state: state)
    let restored = try #require(await coordinator.historyResults(for: deepKey))
    #expect(restored.items.first?.id == deep)
    #expect(restored.newerContinuation != nil)
    let upward = try #require(await coordinator.historyResults(for: deepKey, extending: restored, newer: true))
    #expect(upward.items.count == 31)
    #expect(upward.items.last?.id == deep)

    // A mutation to an unrelated row cannot cause a queued update to mistake this one for missing.
    let unrelated = Transcript(text: "new words", processingTime: 0, backendType: .parakeet)
    try store.save(unrelated)
    let current = try #require(await coordinator.loadCatalogDetail(rowID, authoritative: true))
    #expect(current.id == loaded.id)
    // Simulates an older writer replacing a previously loaded file without a newer app notice.
    try TranscriptStore(directory: root.appendingPathComponent("transcripts")).delete(id: loaded.id)
    #expect(coordinator.textForDelivery(loaded) == nil)
    let relocated = root.appendingPathComponent("transcripts-backup")
    try FileManager.default.moveItem(at: root.appendingPathComponent("transcripts"), to: relocated)
    do {
      _ = try store.historyRowReader()(loaded.id, Date())
      Issue.record("The per-ID reader reported absence while its namespace was unavailable")
    } catch is CocoaError {}
    #expect(coordinator.visibleTranscripts.isEmpty)
    #expect(coordinator.historyReadFinished == false)
  }
}
