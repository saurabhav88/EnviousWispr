import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage
import EnviousWisprAppKitTestSupport

/// History tells a dictation from a transcript (#2808, phase 1 of #2807; tabs since #3147 PR2).
///
/// The tab is view state over `Transcript.isImported`; nothing is stored. Every rule here is
/// what a person sees in a History tab: which rows each tab lists, what its search reaches, and
/// what happens to an open item when a search, an update, an expiry or a deletion takes its row
/// away.
///
/// Lists are read through the production path (#4586): real folders and a real catalog session,
/// as `HistoryCatalogRig` wires them. An open item is no longer closed when its row leaves the
/// list: production never ran that clearing, so its tests are gone.
@MainActor
/// Class: `.productOutcome` — the rows each History tab lists, and whether an open item stays open
/// when the list changes under the user.
@Suite(
  "History filter: dictations, transcripts, and the detail pane (#2808)", .tags(.productOutcome))
struct TranscriptCoordinatorFilterTests {

  // MARK: Fixtures

  private func makeCoordinator() -> (TranscriptCoordinator, TranscriptStore) {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-2808-filter-\(UUID().uuidString)", isDirectory: true)
    let store = TranscriptStore(directory: dir)
    return (TranscriptCoordinator(store: store), store)
  }

  /// A completed dictation. `createdAt` steps backwards so the newest-first order is fixed.
  private func dictation(_ text: String, ageSeconds: TimeInterval = 0) -> Transcript {
    Transcript(text: text, createdAt: Date().addingTimeInterval(-ageSeconds))
  }

  /// A row from Transcribe a File: the file name is the kind.
  private func transcript(_ text: String, file: String, ageSeconds: TimeInterval = 0)
    -> Transcript
  {
    Transcript(
      text: text, language: "en", duration: 61, backendType: .parakeet,
      createdAt: Date().addingTimeInterval(-ageSeconds), importedFileName: file)
  }

  /// A held Escape-recovery row whose retention window began `age` seconds ago.
  private func held(_ text: String, age: TimeInterval) -> Transcript {
    Transcript(
      text: text, createdAt: Date(),
      escapeRecoveredAt: Date().addingTimeInterval(-age),
      escapeRecoveryTakeID: "take-\(text)")
  }

  // MARK: Which rows are listed

  @Test("Dictations and Transcripts each list only their own kind")
  func filterListsByKind() async throws {
    let d1 = dictation("first dictation", ageSeconds: 30)
    let t1 = transcript("an interview", file: "interview.m4a", ageSeconds: 20)
    let d2 = dictation("second dictation", ageSeconds: 10)
    let rig = try await HistoryCatalogRig.make(rows: [d1, t1, d2])
    defer { rig.remove() }

    #expect(await rig.listedRowIDs(.dictations) == [d2.id, d1.id])
    #expect(await rig.listedRowIDs(.transcripts) == [t1.id])
  }

  @Test("search runs inside the tab, and still reaches the imported file name")
  func searchRunsInsideTheFilter() async throws {
    let d = dictation("notes from the marketing call", ageSeconds: 20)
    let t = transcript("we talked about the launch", file: "marketing_sync.wav", ageSeconds: 10)
    let rig = try await HistoryCatalogRig.make(rows: [d, t])
    defer { rig.remove() }

    rig.coordinator.setHistoryQuery("marketing", in: .dictations)
    rig.coordinator.setHistoryQuery("marketing", in: .transcripts)
    #expect(await rig.listedRowIDs(.dictations) == [d.id], "the import is outside the tab")
    #expect(await rig.listedRowIDs(.transcripts) == [t.id], "found by its file name")
  }

  @Test("search matches a renamed speaker's name, which does not enter displayText (#2811)")
  func searchMatchesSpeakerNames() async throws {
    let labeled = Transcript(
      text: "hello there friend", language: "en", duration: 61, backendType: .parakeet,
      importedFileName: "interview.m4a", speakerAnalysis: .labeled(count: 2),
      speakerNames: ["A": "Zach", "B": "Ariana"],
      turns: [
        Turn(id: "0-5", speakerId: "A", startMs: 0, endMs: 200, originalTextRange: 0..<5),
        Turn(id: "6-18", speakerId: "B", startMs: 5000, endMs: 5400, originalTextRange: 6..<18),
      ])
    let unrelated = transcript("a totally different recording", file: "other.m4a")
    let rig = try await HistoryCatalogRig.make(rows: [unrelated, labeled])
    defer { rig.remove() }
    let coordinator = rig.coordinator

    coordinator.setHistoryQuery("Zach", in: .transcripts)
    #expect(
      await rig.listedRowIDs(.transcripts) == [labeled.id],
      "a speaker's own name must be searchable even though it never enters displayText")

    coordinator.setHistoryQuery("Ariana", in: .transcripts)
    #expect(await rig.listedRowIDs(.transcripts) == [labeled.id], "every speaker name, not just one")

    coordinator.setHistoryQuery("nobody named this", in: .transcripts)
    #expect(await rig.listedRowIDs(.transcripts).isEmpty)
  }

  @Test("a held recovery is listed under Dictations, never under Transcripts")
  func heldRowIsADictation() async throws {
    let heldRow = held("cancelled words", age: 60)
    let rig = try await HistoryCatalogRig.make(
      rows: [transcript("a file", file: "file.m4a", ageSeconds: 10)], pending: [heldRow])
    defer { rig.remove() }

    #expect(await rig.listedRowIDs(.dictations) == [heldRow.id], "under Dictations")
    #expect(
      await rig.listedRowIDs(.transcripts).contains(heldRow.id) == false,
      "a cancelled take is not a file import")
  }

  @Test("a held recovery is excluded from a nonempty search on every tab")
  func heldRowIsNeverSearched() async throws {
    let heldRow = held("cancelled words", age: 60)
    let rig = try await HistoryCatalogRig.make(pending: [heldRow])
    defer { rig.remove() }

    #expect(await rig.listedRowIDs(.dictations) == [heldRow.id], "listed with no search")
    for tab in HistoryTab.allCases {
      rig.coordinator.setHistoryQuery("cancelled", in: tab)
      #expect(
        await rig.listedRowIDs(tab).contains(heldRow.id) == false,
        "an accidental Escape must not pollute search results under \(tab)")
    }
  }

  // MARK: The counts

  @Test("the listed count never counts a held offer; onboarding's count is dictations only")
  func completedCountSkipsHeldOffers() async throws {
    let (coordinator, store) = makeCoordinator()
    try store.savePending(held("cancelled", age: 60))
    coordinator.load()
    await coordinator.diskReconcilerForTesting.waitForLoadForTesting()
    try await coordinator.saveAndShow(dictation("one", ageSeconds: 30))
    try await coordinator.saveAndShow(dictation("two", ageSeconds: 20))
    try await coordinator.saveAndShow(transcript("three", file: "three.m4a", ageSeconds: 10))

    #expect(
      coordinator.visibleTranscripts.filter { $0.escapeRecoveredAt == nil }.count == 3,
      "three completed rows, the held offer is not one")
    #expect(coordinator.dictationCount == 2)
    coordinator.setHistoryQuery("two", in: .dictations)
    #expect(coordinator.dictationCount == 2, "onboarding's count does not follow a tab's search")
  }

  // MARK: The open item

  @Test("deleting a row that is not open leaves the open item alone")
  func deleteOfAnotherRowKeepsTheSelection() async throws {
    let (coordinator, _) = makeCoordinator()
    let t1 = transcript("first", file: "first.m4a", ageSeconds: 10)
    let t2 = transcript("second", file: "second.m4a")
    try await coordinator.saveAndShow(t1)
    try await coordinator.saveAndShow(t2)

    coordinator.openHistoryItem(.transcript(t1.id), in: .transcripts)
    await coordinator.delete(t2)
    #expect(coordinator.openHistoryItemID(in: .transcripts) == .transcript(t1.id))
  }

  @Test("Delete All empties every tab")
  func deleteAllShowsNothing() async throws {
    let t = transcript("a file", file: "file.m4a")
    let rig = try await HistoryCatalogRig.make(rows: [dictation("a dictation"), t])
    defer { rig.remove() }
    let coordinator = rig.coordinator
    #expect(await rig.listedRowIDs(.transcripts) == [t.id], "precondition: there is something")

    let confirmation = try #require(await coordinator.deleteAllConfirmation())
    await coordinator.deleteAll(confirmedSource: confirmation.source)
    await rig.settle()
    for tab in HistoryTab.allCases { #expect(await rig.listedRowIDs(tab).isEmpty) }
  }

  // Deleted (#4586): "a cleanup that stops an open import matching the search closes it" and
  // "an open recovery that expires closes". Both asserted only that an open item is cleared
  // when its row leaves the list, which `historyState(for:)` did and production never called.

  // Deleted (#4586): "listing one kind of 25,000 rows costs the same order as listing another"
  // compared two passes over the in-memory array. The catalog filters by tab in SQL, so there is
  // no such pass; nothing a person sees is lost.

  // MARK: Rows the store would refuse to return

  @Test("an expired recovery is listed on no tab")
  func expiredRowIsNeverListed() async throws {
    let expired = held("expired", age: AppConstants.pendingTranscriptRetention + 60)
    let kept = dictation("kept")
    let rig = try await HistoryCatalogRig.make(rows: [kept], pending: [expired])
    defer { rig.remove() }

    for tab in HistoryTab.allCases {
      #expect(
        await rig.listedRowIDs(tab).contains(expired.id) == false, "expired under \(tab)")
    }
    #expect(await rig.listedRowIDs(.dictations) == [kept.id])
  }

  #if DEBUG
    @Test("an expired recovery is not counted")
    func expiredRowIsNotCounted() {
      let (coordinator, _) = makeCoordinator()
      let expired = held("expired", age: AppConstants.pendingTranscriptRetention + 60)
      let kept = dictation("kept")
      coordinator.setTranscriptsForTesting([expired, kept])

      #expect(
        coordinator.visibleTranscripts.map(\.id) == [kept.id],
        "the kept dictation is the only row visible, so the only one counted")
    }
  #endif
}
