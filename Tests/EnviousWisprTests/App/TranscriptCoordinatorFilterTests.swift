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
/// Rows go through a real `TranscriptStore` under a temp directory, the way the coordinator's
/// other suites do, so the in-memory contract is asserted against real disk semantics.
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
    let (coordinator, _) = makeCoordinator()
    let d1 = dictation("first dictation", ageSeconds: 30)
    let t1 = transcript("an interview", file: "interview.m4a", ageSeconds: 20)
    let d2 = dictation("second dictation", ageSeconds: 10)
    try await coordinator.saveAndShow(d1)
    try await coordinator.saveAndShow(t1)
    try await coordinator.saveAndShow(d2)

    #expect(coordinator.matchingRowIDs(in: .dictations) == [d2.id, d1.id])
    #expect(coordinator.matchingRowIDs(in: .transcripts) == [t1.id])
  }

  @Test("search runs inside the tab, and still reaches the imported file name")
  func searchRunsInsideTheFilter() async throws {
    let (coordinator, _) = makeCoordinator()
    let d = dictation("notes from the marketing call", ageSeconds: 20)
    let t = transcript("we talked about the launch", file: "marketing_sync.wav", ageSeconds: 10)
    try await coordinator.saveAndShow(d)
    try await coordinator.saveAndShow(t)

    coordinator.setHistoryQuery("marketing", in: .dictations)
    coordinator.setHistoryQuery("marketing", in: .transcripts)
    #expect(coordinator.matchingRowIDs(in: .dictations) == [d.id], "the import is outside the tab")
    #expect(coordinator.matchingRowIDs(in: .transcripts) == [t.id], "found by its file name")
  }

  @Test("search matches a renamed speaker's name, which does not enter displayText (#2811)")
  func searchMatchesSpeakerNames() async throws {
    let (coordinator, _) = makeCoordinator()
    let labeled = Transcript(
      text: "hello there friend", language: "en", duration: 61, backendType: .parakeet,
      importedFileName: "interview.m4a", speakerAnalysis: .labeled(count: 2),
      speakerNames: ["A": "Zach", "B": "Ariana"],
      turns: [
        Turn(id: "0-5", speakerId: "A", startMs: 0, endMs: 200, originalTextRange: 0..<5),
        Turn(id: "6-18", speakerId: "B", startMs: 5000, endMs: 5400, originalTextRange: 6..<18),
      ])
    let unrelated = transcript("a totally different recording", file: "other.m4a")
    try await coordinator.saveAndShow(unrelated)
    try await coordinator.saveAndShow(labeled)

    coordinator.setHistoryQuery("Zach", in: .transcripts)
    #expect(
      coordinator.matchingRowIDs(in: .transcripts) == [labeled.id],
      "a speaker's own name must be searchable even though it never enters displayText")

    coordinator.setHistoryQuery("Ariana", in: .transcripts)
    #expect(
      coordinator.matchingRowIDs(in: .transcripts) == [labeled.id],
      "every speaker name, not just one")

    coordinator.setHistoryQuery("nobody named this", in: .transcripts)
    #expect(coordinator.matchingRowIDs(in: .transcripts).isEmpty)
  }

  @Test("a held recovery is listed under Dictations, never under Transcripts")
  func heldRowIsADictation() async throws {
    let (coordinator, store) = makeCoordinator()
    let heldRow = held("cancelled words", age: 60)
    try store.savePending(heldRow)
    try store.save(transcript("a file", file: "file.m4a", ageSeconds: 10))
    coordinator.load()
    await coordinator.diskReconcilerForTesting.waitForLoadForTesting()

    #expect(coordinator.matchingRowIDs(in: .dictations) == [heldRow.id], "under Dictations")
    #expect(
      coordinator.matchingRowIDs(in: .transcripts).contains(heldRow.id) == false,
      "a cancelled take is not a file import")
  }

  @Test("a held recovery is excluded from a nonempty search on every tab")
  func heldRowIsNeverSearched() async throws {
    let (coordinator, store) = makeCoordinator()
    let heldRow = held("cancelled words", age: 60)
    try store.savePending(heldRow)
    coordinator.load()
    await coordinator.diskReconcilerForTesting.waitForLoadForTesting()

    #expect(coordinator.matchingRowIDs(in: .dictations) == [heldRow.id], "listed with no search")
    for tab in HistoryTab.allCases {
      coordinator.setHistoryQuery("cancelled", in: tab)
      #expect(
        coordinator.matchingRowIDs(in: tab).contains(heldRow.id) == false,
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

    #expect(coordinator.completedItemCount == 3, "three completed rows, the held offer is not one")
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

  @Test("Delete All closes the open item and empties every tab")
  func deleteAllShowsNothing() async throws {
    let (coordinator, _) = makeCoordinator()
    let t = transcript("a file", file: "file.m4a")
    try await coordinator.saveAndShow(dictation("a dictation"))
    try await coordinator.saveAndShow(t)
    coordinator.openHistoryItem(.transcript(t.id), in: .transcripts)
    await coordinator.deleteAll()
    #expect(coordinator.openHistoryItemID(in: .transcripts) == nil)
    for tab in HistoryTab.allCases { #expect(coordinator.matchingRowIDs(in: tab).isEmpty) }
  }

  @Test("a cleanup that stops an open import matching the search closes it")
  func aRowUpdateThatLeavesTheSearchClearsTheSelection() async throws {
    let (coordinator, _) = makeCoordinator()
    let raw = transcript("um so the plan is", file: "plan.m4a")
    try await coordinator.saveAndShow(raw)
    coordinator.setHistoryQuery("um", in: .transcripts)
    coordinator.openHistoryItem(.transcript(raw.id), in: .transcripts)
    #expect(coordinator.openHistoryItemID(in: .transcripts) == .transcript(raw.id))

    let cleaned = Transcript(
      id: raw.id, text: raw.text, polishedText: "So the plan is.", language: "en", duration: 61,
      backendType: .parakeet, createdAt: raw.createdAt, importedFileName: "plan.m4a")
    try await coordinator.updateExistingRow(cleaned)
    #expect(coordinator.openHistoryItemID(in: .transcripts) == nil, "the row left the tab's list")
  }

  // MARK: Cost

  /// The kind filter is one more pass over the same array as the search, so it must cost the
  /// same order as the pass History already makes. A relation between two passes measured in
  /// one process, never an absolute: an absolute would freeze this machine, not the code.
  @Test("listing one kind of 25,000 rows costs the same order as listing another")
  func filterCostIsTheSameOrderAsListing() throws {
    let (coordinator, _) = makeCoordinator()
    var rows: [Transcript] = []
    rows.reserveCapacity(25_000)
    for i in 0..<25_000 {
      rows.append(
        i % 5 == 0
          ? transcript("row \(i)", file: "file-\(i).m4a", ageSeconds: TimeInterval(i))
          : dictation("row \(i)", ageSeconds: TimeInterval(i)))
    }
    // Bulk seam in both configurations (#3013): the Release fallback used to be
    // `saveAndShow` per row, 25,000 writes before the stopwatch started.
    coordinator.setTranscriptsForTesting(rows)

    let clock = ContinuousClock()
    func fastest(_ body: () -> Int) -> (Duration, Int) {
      var best: Duration = .seconds(1_000)
      var count = 0
      for _ in 0..<3 {
        let start = clock.now
        count = body()
        best = min(best, clock.now - start)
      }
      return (best, count)
    }

    let (unfiltered, allCount) = fastest { coordinator.matchingHistoryItems(in: .dictations).count }
    let (filtered, transcriptCount) = fastest {
      coordinator.matchingHistoryItems(in: .transcripts).count
    }

    #expect(allCount == 20_000)
    #expect(transcriptCount == 5_000)
    #expect(
      filtered <= unfiltered * 4,
      "one extra pass over the array must stay within a small multiple of the pass History already makes: filtered \(filtered) vs listed \(unfiltered)"
    )
  }

  #if DEBUG
    // MARK: Rows the store would refuse to return

    @Test("an expired recovery is listed on no tab")
    func expiredRowIsNeverListed() {
      let (coordinator, _) = makeCoordinator()
      let expired = held("expired", age: AppConstants.pendingTranscriptRetention + 60)
      let kept = dictation("kept")
      coordinator.setTranscriptsForTesting([expired, kept])

      for tab in HistoryTab.allCases {
        #expect(
          coordinator.matchingRowIDs(in: tab).contains(expired.id) == false, "expired under \(tab)")
      }
      #expect(coordinator.matchingRowIDs(in: .dictations) == [kept.id])
      #expect(coordinator.completedItemCount == 1, "the kept dictation is the only row counted")
    }

    @Test("an open recovery that expires closes")
    func selectedRowExpiringIsEmptyNotFallback() {
      let (coordinator, _) = makeCoordinator()
      let live = held("cancelled", age: 60)
      coordinator.setTranscriptsForTesting([live])
      coordinator.openHistoryItem(.transcript(live.id), in: .dictations)
      #expect(coordinator.openHistoryItemID(in: .dictations) == .transcript(live.id))

      // The same row, past its window: what read-time expiry sees on the next render.
      let expired = Transcript(
        id: live.id, text: live.text, createdAt: live.createdAt,
        escapeRecoveredAt: Date().addingTimeInterval(-AppConstants.pendingTranscriptRetention - 60),
        escapeRecoveryTakeID: live.escapeRecoveryTakeID)
      coordinator.setTranscriptsForTesting([expired])
      #expect(coordinator.openHistoryItemID(in: .dictations) == nil)
    }
  #endif
}
