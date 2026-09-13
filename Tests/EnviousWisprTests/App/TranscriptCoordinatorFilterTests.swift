import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// History tells a dictation from a transcript (#2808, phase 1 of #2807).
///
/// The filter is view state over `Transcript.isImported`; nothing is stored. Every rule here
/// is what a person sees in the History list and its detail pane: which rows are listed under
/// each filter, what the count beside the search box says, what the empty list says, and what
/// the detail pane shows after a filter, a search or a deletion takes the selected row away.
///
/// Rows go through a real `TranscriptStore` under a temp directory, the way the coordinator's
/// other suites do, so the in-memory contract is asserted against real disk semantics.
@MainActor
/// Class: `.productOutcome` — the rows History lists, the count beside them, and what the detail
/// pane shows when the list changes under the user.
@Suite(
  "History filter: dictations, transcripts, and the detail pane (#2808)", .tags(.productOutcome))
struct TranscriptCoordinatorFilterTests {

  // MARK: Fixtures

  private func makeCoordinator() -> (TranscriptCoordinator, TranscriptStore) {
    let dir = FileManager.default.temporaryDirectory
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

  private func ids(_ rows: [Transcript]) -> [UUID] { rows.map(\.id) }

  private func isRow(_ detail: HistoryDetail, _ id: UUID) -> Bool {
    if case .row(let row) = detail { return row.id == id }
    return false
  }

  private func isEmpty(_ detail: HistoryDetail) -> Bool {
    if case .empty = detail { return true }
    return false
  }

  private func isLiveFallback(_ detail: HistoryDetail) -> Bool {
    if case .liveFallback = detail { return true }
    return false
  }

  // MARK: Which rows are listed

  @Test("All lists both kinds; Dictations and Transcripts each list only their own")
  func filterListsByKind() throws {
    let (coordinator, _) = makeCoordinator()
    let d1 = dictation("first dictation", ageSeconds: 30)
    let t1 = transcript("an interview", file: "interview.m4a", ageSeconds: 20)
    let d2 = dictation("second dictation", ageSeconds: 10)
    try coordinator.saveAndShow(d1)
    try coordinator.saveAndShow(t1)
    try coordinator.saveAndShow(d2)

    #expect(coordinator.historyFilter == .all, "a fresh coordinator starts at All")
    #expect(ids(coordinator.filteredTranscripts) == [d2.id, t1.id, d1.id])

    coordinator.historyFilter = .dictations
    #expect(ids(coordinator.filteredTranscripts) == [d2.id, d1.id])

    coordinator.historyFilter = .transcripts
    #expect(ids(coordinator.filteredTranscripts) == [t1.id])
  }

  @Test("search runs inside the filter, and still reaches the imported file name")
  func searchRunsInsideTheFilter() throws {
    let (coordinator, _) = makeCoordinator()
    let d = dictation("notes from the marketing call", ageSeconds: 20)
    let t = transcript("we talked about the launch", file: "marketing_sync.wav", ageSeconds: 10)
    try coordinator.saveAndShow(d)
    try coordinator.saveAndShow(t)

    coordinator.searchQuery = "marketing"
    #expect(ids(coordinator.filteredTranscripts) == [t.id, d.id], "both match under All")

    coordinator.historyFilter = .dictations
    #expect(ids(coordinator.filteredTranscripts) == [d.id], "the import is outside the filter")

    coordinator.historyFilter = .transcripts
    #expect(ids(coordinator.filteredTranscripts) == [t.id], "found by its file name")
  }

  @Test("search matches a renamed speaker's name, which does not enter displayText (#2811)")
  func searchMatchesSpeakerNames() throws {
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
    try coordinator.saveAndShow(unrelated)
    try coordinator.saveAndShow(labeled)

    coordinator.searchQuery = "Zach"
    #expect(
      ids(coordinator.filteredTranscripts) == [labeled.id],
      "a speaker's own name must be searchable even though it never enters displayText")

    coordinator.searchQuery = "Ariana"
    #expect(
      ids(coordinator.filteredTranscripts) == [labeled.id], "every speaker name, not just one")

    coordinator.searchQuery = "nobody named this"
    #expect(coordinator.filteredTranscripts.isEmpty)
  }

  @Test("a held recovery is listed under All and Dictations, never under Transcripts")
  func heldRowIsADictation() async throws {
    let (coordinator, store) = makeCoordinator()
    let heldRow = held("cancelled words", age: 60)
    try store.savePending(heldRow)
    try store.save(transcript("a file", file: "file.m4a", ageSeconds: 10))
    coordinator.load()
    await coordinator.waitForLoadForTesting()

    #expect(ids(coordinator.filteredTranscripts).contains(heldRow.id), "under All")

    coordinator.historyFilter = .dictations
    #expect(ids(coordinator.filteredTranscripts) == [heldRow.id], "under Dictations")

    coordinator.historyFilter = .transcripts
    #expect(
      ids(coordinator.filteredTranscripts).contains(heldRow.id) == false,
      "a cancelled take is not a file import")
  }

  @Test("a held recovery is excluded from a nonempty search under every filter")
  func heldRowIsNeverSearched() async throws {
    let (coordinator, store) = makeCoordinator()
    let heldRow = held("cancelled words", age: 60)
    try store.savePending(heldRow)
    coordinator.load()
    await coordinator.waitForLoadForTesting()

    for filter in HistoryFilter.allCases {
      coordinator.historyFilter = filter
      coordinator.searchQuery = "cancelled"
      #expect(
        ids(coordinator.filteredTranscripts).contains(heldRow.id) == false,
        "an accidental Escape must not pollute search results under \(filter)")
      coordinator.searchQuery = ""
    }
  }

  // MARK: The count beside the search box

  @Test("the listed count follows the filter and the search, and never counts a held offer")
  func listedCountFollowsTheFilter() async throws {
    let (coordinator, store) = makeCoordinator()
    try store.savePending(held("cancelled", age: 60))
    coordinator.load()
    await coordinator.waitForLoadForTesting()
    try coordinator.saveAndShow(dictation("one", ageSeconds: 30))
    try coordinator.saveAndShow(dictation("two", ageSeconds: 20))
    try coordinator.saveAndShow(transcript("three", file: "three.m4a", ageSeconds: 10))

    #expect(coordinator.listedCount == 3, "three completed rows, the held offer is not one")
    #expect(coordinator.dictationCount == 2)

    coordinator.historyFilter = .dictations
    #expect(coordinator.listedCount == 2)
    coordinator.historyFilter = .transcripts
    #expect(coordinator.listedCount == 1)
    #expect(coordinator.dictationCount == 2, "onboarding's count does not follow the filter")

    coordinator.historyFilter = .all
    coordinator.searchQuery = "two"
    #expect(coordinator.listedCount == 1)
  }

  // MARK: The empty list

  @Test("each way of being empty has its own sentence")
  func emptyStates() throws {
    let (coordinator, _) = makeCoordinator()
    #expect(coordinator.emptyState == .nothingYet)

    try coordinator.saveAndShow(dictation("a dictation"))
    #expect(coordinator.emptyState == nil)

    coordinator.historyFilter = .transcripts
    #expect(coordinator.emptyState == .noTranscripts)

    coordinator.historyFilter = .all
    coordinator.searchQuery = "nothing like this"
    #expect(coordinator.emptyState == .noMatches)

    coordinator.searchQuery = ""
    coordinator.deleteAll()
    #expect(coordinator.emptyState == .nothingYet, "an emptied History is back to nothing yet")

    try coordinator.saveAndShow(transcript("a file", file: "file.m4a"))
    coordinator.historyFilter = .dictations
    #expect(coordinator.emptyState == .noDictations)
  }

  // MARK: The detail pane

  @Test("nothing selected on a fresh History shows the live transcript, as before")
  func freshHistoryFallsBackToTheLiveTranscript() {
    let (coordinator, _) = makeCoordinator()
    #expect(isLiveFallback(coordinator.detail))
  }

  @Test("a selected row that the filter stops listing is cleared and the pane goes empty")
  func filterClearsASelectionItNoLongerLists() throws {
    let (coordinator, _) = makeCoordinator()
    let d = dictation("a dictation", ageSeconds: 10)
    let t = transcript("a file", file: "file.m4a")
    try coordinator.saveAndShow(d)
    try coordinator.saveAndShow(t)

    coordinator.selectedTranscriptID = d.id
    #expect(isRow(coordinator.detail, d.id))

    coordinator.historyFilter = .transcripts
    #expect(coordinator.selectedTranscriptID == nil, "the selection left the displayed set")
    #expect(isEmpty(coordinator.detail), "and the live transcript must not stand in for it")

    coordinator.historyFilter = .all
    #expect(isEmpty(coordinator.detail), "widening the filter does not bring the fallback back")

    coordinator.selectedTranscriptID = t.id
    #expect(isRow(coordinator.detail, t.id), "picking a row is what shows something again")
  }

  @Test("a search that hides the selected row clears it and the pane goes empty")
  func searchClearsASelectionItNoLongerLists() throws {
    let (coordinator, _) = makeCoordinator()
    let d = dictation("apples", ageSeconds: 10)
    try coordinator.saveAndShow(d)
    try coordinator.saveAndShow(dictation("pears"))

    coordinator.selectedTranscriptID = d.id
    coordinator.searchQuery = "pears"
    #expect(coordinator.selectedTranscriptID == nil)
    #expect(isEmpty(coordinator.detail))

    coordinator.searchQuery = ""
    #expect(isEmpty(coordinator.detail), "clearing the search does not bring the fallback back")
  }

  @Test("a selected row that stops being listed without a filter change is empty, not the fallback")
  func staleSelectionIsEmptyNotFallback() throws {
    let (coordinator, _) = makeCoordinator()
    let d = dictation("a dictation")
    try coordinator.saveAndShow(d)
    coordinator.selectedTranscriptID = d.id

    // Selected ids that no longer resolve arrive from outside this object: a row that expired
    // between renders, or the list's binding carrying an id from before a reload.
    coordinator.selectedTranscriptID = UUID()
    #expect(isEmpty(coordinator.detail))
  }

  @Test("the user deselecting shows nothing rather than the live transcript")
  func deselectionSuppressesTheFallback() throws {
    let (coordinator, _) = makeCoordinator()
    let d = dictation("a dictation")
    try coordinator.saveAndShow(d)

    coordinator.selectedTranscriptID = d.id
    coordinator.selectedTranscriptID = nil
    #expect(isEmpty(coordinator.detail))
  }

  @Test("deleting the selected row under a filter selects its neighbour in that filter")
  func deleteSelectsTheNeighbourInTheSameFilter() throws {
    let (coordinator, _) = makeCoordinator()
    let d1 = dictation("first", ageSeconds: 30)
    let t = transcript("a file", file: "file.m4a", ageSeconds: 20)
    let d2 = dictation("second", ageSeconds: 10)
    let d3 = dictation("third", ageSeconds: 0)
    for row in [d1, t, d2, d3] { try coordinator.saveAndShow(row) }

    coordinator.historyFilter = .dictations
    // Displayed order is newest first: d3, d2, d1. Delete the middle one.
    coordinator.selectedTranscriptID = d2.id
    coordinator.delete(d2)
    #expect(coordinator.selectedTranscriptID == d1.id, "the row after it in the same filter")
    #expect(isRow(coordinator.detail, d1.id))

    // Delete the last row: nothing after it, so the one before it.
    coordinator.delete(d1)
    #expect(coordinator.selectedTranscriptID == d3.id)

    // Delete the only remaining dictation: nothing to select, and no fallback.
    coordinator.delete(d3)
    #expect(coordinator.selectedTranscriptID == nil)
    #expect(isEmpty(coordinator.detail))
    #expect(coordinator.emptyState == .noDictations)

    coordinator.historyFilter = .all
    #expect(ids(coordinator.filteredTranscripts) == [t.id], "the transcript was never touched")
  }

  @Test("deleting a row that is not selected leaves the selection alone")
  func deleteOfAnotherRowKeepsTheSelection() throws {
    let (coordinator, _) = makeCoordinator()
    let d1 = dictation("first", ageSeconds: 10)
    let d2 = dictation("second")
    try coordinator.saveAndShow(d1)
    try coordinator.saveAndShow(d2)

    coordinator.selectedTranscriptID = d1.id
    coordinator.delete(d2)
    #expect(coordinator.selectedTranscriptID == d1.id)
    #expect(isRow(coordinator.detail, d1.id))
  }

  @Test("Delete All empties the pane, whatever the live pipeline last produced")
  func deleteAllShowsNothing() throws {
    let (coordinator, _) = makeCoordinator()
    try coordinator.saveAndShow(dictation("a dictation"))
    coordinator.deleteAll()
    #expect(isEmpty(coordinator.detail))
    #expect(coordinator.emptyState == .nothingYet)
  }

  @Test("a completed dictation landing in the displayed set lets the live transcript show again")
  func aCompletedDictationRestoresTheFallback() throws {
    let (coordinator, _) = makeCoordinator()
    let d = dictation("a dictation")
    try coordinator.saveAndShow(d)
    coordinator.selectedTranscriptID = d.id
    coordinator.delete(d)
    #expect(isEmpty(coordinator.detail), "the deletion suppressed the fallback")

    let finished = dictation("just finished")
    coordinator.append(finished)
    #expect(isRow(coordinator.detail, finished.id), "the pane shows the dictation's own row")
  }

  @Test("narrowing the list away from the dictation the pane is showing empties the pane")
  func narrowingAwayFromTheFallbackRowEmptiesThePane() {
    let (coordinator, _) = makeCoordinator()
    let finished = dictation("just finished")
    coordinator.append(finished)
    #expect(isRow(coordinator.detail, finished.id))

    coordinator.historyFilter = .dictations
    #expect(isRow(coordinator.detail, finished.id), "the dictation is still listed")

    coordinator.historyFilter = .transcripts
    #expect(isEmpty(coordinator.detail), "the list no longer shows what the pane shows")

    coordinator.historyFilter = .all
    #expect(isEmpty(coordinator.detail), "widening does not bring it back")
  }

  @Test("a search that hides the dictation the pane is showing empties the pane")
  func searchAwayFromTheFallbackRowEmptiesThePane() {
    let (coordinator, _) = makeCoordinator()
    let finished = dictation("just finished")
    coordinator.append(finished)

    coordinator.searchQuery = "finished"
    #expect(isRow(coordinator.detail, finished.id), "the dictation matches, so it is still listed")

    coordinator.searchQuery = "nothing like this"
    #expect(isEmpty(coordinator.detail))

    coordinator.searchQuery = ""
    #expect(isEmpty(coordinator.detail), "clearing the search does not bring it back")
  }

  @Test("a completion the search does not list suppresses a fallback that was showing")
  func aCompletionOutsideTheSearchSuppressesAnActiveFallback() {
    let (coordinator, _) = makeCoordinator()
    coordinator.searchQuery = "apples"
    let apples = dictation("apples", ageSeconds: 10)
    coordinator.append(apples)
    #expect(isRow(coordinator.detail, apples.id), "the completion matches the search")

    coordinator.append(dictation("pears"))
    #expect(isEmpty(coordinator.detail), "the pane would otherwise show pears beside apples")

    coordinator.searchQuery = ""
    #expect(isEmpty(coordinator.detail), "clearing the search does not bring it back")
  }

  @Test("before any dictation lands, narrowing the list suppresses the fallback")
  func narrowingWithNoKnownFallbackRowSuppressesIt() throws {
    let (coordinator, _) = makeCoordinator()
    try coordinator.saveAndShow(transcript("a file", file: "file.m4a"))
    #expect(isLiveFallback(coordinator.detail), "nothing has narrowed the list")

    coordinator.historyFilter = .transcripts
    #expect(isEmpty(coordinator.detail), "nothing can prove the pane's text is on screen")
  }

  @Test("deleting the dictation the pane is showing through the fallback empties the pane")
  func deletingTheFallbackRowEmptiesThePane() throws {
    let (coordinator, _) = makeCoordinator()
    let d = dictation("just finished")
    try coordinator.saveAndShow(d)
    coordinator.append(dictation("older, but appended second", ageSeconds: 10))
    let shown = dictation("shown")
    coordinator.append(shown)
    #expect(isRow(coordinator.detail, shown.id))

    coordinator.delete(d)
    #expect(isRow(coordinator.detail, shown.id), "another row went, the pane's row is still here")

    coordinator.delete(shown)
    #expect(isEmpty(coordinator.detail))
  }

  @Test("the pane shows the just-finished dictation from History, not a second copy of it")
  func thePaneShowsTheFinishedDictationsOwnRow() throws {
    let (coordinator, _) = makeCoordinator()
    let finished = dictation("just finished")
    coordinator.append(finished)
    #expect(isRow(coordinator.detail, finished.id))
    #expect(
      isLiveFallback(coordinator.detail) == false,
      "once History has the row, the live pipeline's copy is never the source")
  }

  @Test("a cleanup that stops a selected import matching the search clears the selection")
  func aRowUpdateThatLeavesTheSearchClearsTheSelection() throws {
    let (coordinator, _) = makeCoordinator()
    let raw = transcript("um so the plan is", file: "plan.m4a")
    try coordinator.saveAndShow(raw)
    coordinator.searchQuery = "um"
    coordinator.selectedTranscriptID = raw.id
    #expect(isRow(coordinator.detail, raw.id))

    let cleaned = Transcript(
      id: raw.id, text: raw.text, polishedText: "So the plan is.", language: "en", duration: 61,
      backendType: .parakeet, createdAt: raw.createdAt, importedFileName: "plan.m4a")
    try coordinator.updateExistingRow(cleaned)
    #expect(coordinator.selectedTranscriptID == nil, "the row left the displayed set")
    #expect(isEmpty(coordinator.detail))

    coordinator.searchQuery = ""
    #expect(isEmpty(coordinator.detail), "clearing the search does not bring it back")
  }

  @Test("a held recovery arriving does not bring the live transcript back")
  func aHeldRecoveryDoesNotRestoreTheFallback() throws {
    let (coordinator, _) = makeCoordinator()
    let d = dictation("a dictation")
    try coordinator.saveAndShow(d)
    coordinator.selectedTranscriptID = d.id
    coordinator.delete(d)

    coordinator.append(held("cancelled", age: 1))
    #expect(isEmpty(coordinator.detail), "a cancellation is not a completion")
  }

  @Test("a dictation arriving outside the current filter does not bring the live transcript back")
  func aDictationOutsideTheFilterDoesNotRestoreTheFallback() throws {
    let (coordinator, _) = makeCoordinator()
    let t = transcript("a file", file: "file.m4a")
    try coordinator.saveAndShow(t)
    coordinator.selectedTranscriptID = t.id
    coordinator.historyFilter = .dictations
    #expect(isEmpty(coordinator.detail))

    coordinator.historyFilter = .transcripts
    coordinator.append(dictation("just finished"))
    #expect(isEmpty(coordinator.detail), "the new row is not on screen, so nothing changed")
  }

  @Test("an import's second write does not bring the live transcript back")
  func anImportUpdateDoesNotRestoreTheFallback() throws {
    let (coordinator, _) = makeCoordinator()
    let d = dictation("a dictation")
    try coordinator.saveAndShow(d)
    coordinator.selectedTranscriptID = d.id
    coordinator.delete(d)

    let raw = transcript("raw words", file: "file.m4a")
    try coordinator.saveAndShow(raw)
    #expect(isEmpty(coordinator.detail), "an import is not the dictation the fallback shows")
    try coordinator.updateExistingRow(raw)
    #expect(isEmpty(coordinator.detail))
  }

  // MARK: Cost

  /// The kind filter is one more pass over the same array as the search, so it must cost the
  /// same order as the pass History already makes. A relation between two passes measured in
  /// one process, never an absolute: an absolute would freeze this machine, not the code.
  @Test("filtering 25,000 rows costs the same order as listing them")
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
    #if DEBUG
      coordinator.setTranscriptsForTesting(rows)
    #else
      for row in rows { try coordinator.saveAndShow(row) }
    #endif

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

    coordinator.historyFilter = .all
    let (unfiltered, allCount) = fastest { coordinator.filteredTranscripts.count }
    coordinator.historyFilter = .transcripts
    let (filtered, transcriptCount) = fastest { coordinator.filteredTranscripts.count }

    #expect(allCount == 25_000)
    #expect(transcriptCount == 5_000)
    #expect(
      filtered <= unfiltered * 4,
      "one extra pass over the array must stay within a small multiple of the pass History already makes: filtered \(filtered) vs listed \(unfiltered)"
    )
  }

  #if DEBUG
    // MARK: Rows the store would refuse to return

    @Test("an expired recovery is listed under no filter")
    func expiredRowIsNeverListed() {
      let (coordinator, _) = makeCoordinator()
      let expired = held("expired", age: AppConstants.pendingTranscriptRetention + 60)
      coordinator.setTranscriptsForTesting([expired, dictation("kept")])

      for filter in HistoryFilter.allCases {
        coordinator.historyFilter = filter
        #expect(
          ids(coordinator.filteredTranscripts).contains(expired.id) == false,
          "expired under \(filter)")
      }
      coordinator.historyFilter = .all
      #expect(coordinator.listedCount == 1, "the kept dictation is the only row counted")
    }

    @Test("a selected recovery that expires shows nothing, not the live transcript")
    func selectedRowExpiringIsEmptyNotFallback() {
      let (coordinator, _) = makeCoordinator()
      let live = held("cancelled", age: 60)
      coordinator.setTranscriptsForTesting([live])
      coordinator.selectedTranscriptID = live.id
      #expect(isRow(coordinator.detail, live.id))

      // The same row, past its window: what read-time expiry sees on the next render.
      let expired = Transcript(
        id: live.id, text: live.text, createdAt: live.createdAt,
        escapeRecoveredAt: Date().addingTimeInterval(-AppConstants.pendingTranscriptRetention - 60),
        escapeRecoveryTakeID: live.escapeRecoveryTakeID)
      coordinator.setTranscriptsForTesting([expired])
      #expect(isEmpty(coordinator.detail))
    }

    /// Cloud review of PR #2815: the stale id must not hide the NEXT dictation. Two doors
    /// close it: the sweep that evicts the expired row clears the selection where the expiry
    /// is detected, and `append` treats a selection that resolves to nothing as none.
    @Test("a selected recovery that expired does not hide the next completed dictation")
    func expiredSelectionDoesNotHideTheNextDictation() async {
      let (coordinator, _) = makeCoordinator()
      let live = held("cancelled", age: 60)
      coordinator.setTranscriptsForTesting([live])
      coordinator.selectedTranscriptID = live.id

      let expired = Transcript(
        id: live.id, text: live.text, createdAt: live.createdAt,
        escapeRecoveredAt: Date().addingTimeInterval(-AppConstants.pendingTranscriptRetention - 60),
        escapeRecoveryTakeID: live.escapeRecoveryTakeID)
      coordinator.setTranscriptsForTesting([expired])

      // Door one: the sweep evicts the lapsed row and clears the selection with it.
      await coordinator.sweepExpiredPending()
      #expect(coordinator.selectedTranscriptID == nil, "the expiry cleared the selection")
      #expect(isEmpty(coordinator.detail))

      let finished = dictation("just finished")
      coordinator.append(finished)
      #expect(isRow(coordinator.detail, finished.id), "the new dictation shows")
    }

    @Test("a stale selection at the moment a dictation completes is treated as no selection")
    func staleSelectionAtAppendIsTreatedAsNone() {
      let (coordinator, _) = makeCoordinator()
      let live = held("cancelled", age: 60)
      coordinator.setTranscriptsForTesting([live])
      coordinator.selectedTranscriptID = live.id
      let expired = Transcript(
        id: live.id, text: live.text, createdAt: live.createdAt,
        escapeRecoveredAt: Date().addingTimeInterval(-AppConstants.pendingTranscriptRetention - 60),
        escapeRecoveryTakeID: live.escapeRecoveryTakeID)
      // No sweep has run: door two alone must open.
      coordinator.setTranscriptsForTesting([expired])

      let finished = dictation("just finished")
      coordinator.append(finished)
      #expect(coordinator.selectedTranscriptID == nil)
      #expect(isRow(coordinator.detail, finished.id))
    }
  #endif
}
