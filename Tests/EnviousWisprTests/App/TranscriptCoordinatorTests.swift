import EnviousWisprCore
import Foundation
import os
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage
import EnviousWisprAppKitTestSupport

/// Phase C (#428) — pins the `TranscriptCoordinator` contract around the new
/// in-memory `append(_:)` and the union-by-ID merge in `load()`.
///
/// These replace the pre-Phase-C behavior where `.complete` triggered a
/// full-directory reload. The tests drive the coordinator through real
/// `TranscriptStore(directory:)` instances seeded under a temp directory so
/// the in-memory contract is asserted against real disk semantics — no
/// protocol doubles, no spy layers.
@MainActor
@Suite("TranscriptCoordinator — Phase C append + merge")
struct TranscriptCoordinatorTests {

  // MARK: - Fixtures

  private static func makeTempDir() -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("phase-c-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private static func makeTranscript(
    text: String = "hello",
    createdAt: Date = Date()
  ) -> Transcript {
    Transcript(
      id: UUID(),
      text: text,
      processingTime: 0.1,
      backendType: .parakeet,
      createdAt: createdAt
    )
  }

  private static func writeToDisk(_ transcripts: [Transcript], in dir: URL) throws {
    let encoder = JSONEncoder()
    for t in transcripts {
      let url = dir.appendingPathComponent("\(t.id.uuidString).json")
      let data = try encoder.encode(t)
      try data.write(to: url, options: .atomic)
    }
  }

  // MARK: - two counts (#2772)

  /// The sidebar counts what History lists; onboarding counts dictations. An import is in
  /// the first and not the second. Found by the cloud review of PR #2786, after the single
  /// count had been wrong for each reader in turn.
  @Test("an import counts as a History row and not as a dictation")
  func anImportCountsAsARowNotADictation() async throws {
    let dir = Self.makeTempDir()
    defer { Self.cleanup(dir) }
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    try await coordinator.saveAndShow(Self.makeTranscript(text: "a dictation"))
    try await coordinator.saveAndShow(
      Transcript(
        text: "an import", language: "en", duration: 61, backendType: .parakeet,
        importedFileName: "sync.m4a"))
    #expect(coordinator.listedCount == 2, "History lists two rows")
    #expect(coordinator.dictationCount == 1, "only one of them was dictated")
  }

  // MARK: - search reaches the imported file name (#2772)

  /// The History row shows the imported file's name, and that name is what a person looking
  /// for a meeting they transcribed types. Searching it removed the row while the badge said
  /// the word. Found by the cloud review of PR #2786.
  @Test("searching History by an imported file's name finds the row")
  func searchReachesTheImportedFileName() async throws {
    let dir = Self.makeTempDir()
    defer { Self.cleanup(dir) }
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    let imported = Transcript(
      text: "um so the numbers for the quarter", language: "en", duration: 61,
      backendType: .parakeet, importedFileName: "marketing_sync.wav")
    let dictated = Self.makeTranscript(text: "a plain dictation")
    try await coordinator.saveAndShow(imported)
    try await coordinator.saveAndShow(dictated)

    coordinator.searchQuery = "marketing"
    #expect(coordinator.filteredTranscripts.map(\.id) == [imported.id])
    // The words still work, and a name nobody has does not match anything.
    coordinator.searchQuery = "quarter"
    #expect(coordinator.filteredTranscripts.map(\.id) == [imported.id])
    coordinator.searchQuery = "budget"
    #expect(coordinator.filteredTranscripts.isEmpty)
  }

  // MARK: - updateExistingRow(_:) contract (#2772)

  /// The write a file import's cleanup makes, minutes after its first one.
  ///
  /// History is reachable throughout a cleanup, so the user can delete the row in between.
  /// `saveAndShow` inserts an id it does not find, which put the deleted row back and
  /// rewrote its file. Found by the cloud review of PR #2786.
  ///
  /// Driven through the real store on a temp directory, so the DISK is asserted as well as
  /// the list: a version that only skipped the in-memory insert would still leave the file.
  @Test("updateExistingRow updates a row that is there, and cannot recreate a deleted one")
  func updateExistingRowCannotInsert() async throws {
    let dir = Self.makeTempDir()
    defer { Self.cleanup(dir) }
    let store = TranscriptStore(directory: dir)
    let coordinator = TranscriptCoordinator(store: store)
    let row = Self.makeTranscript(text: "um one two three")
    let onDisk = dir.appendingPathComponent("\(row.id.uuidString).json").path
    let cleaned = row.withImportResult(
      "One two three.", wasPolished: true, llmProvider: "egOne", llmModel: "eg-1")

    try await coordinator.saveAndShow(row)
    #expect(coordinator.hasRow(id: row.id))
    #expect(try await coordinator.updateExistingRow(cleaned) == true)
    #expect(coordinator.visibleTranscripts.count == 1)
    #expect(coordinator.visibleTranscripts.first?.displayText == "One two three.")
    #expect(FileManager.default.fileExists(atPath: onDisk))

    await coordinator.delete(row)
    #expect(coordinator.visibleTranscripts.isEmpty)
    #expect(!coordinator.hasRow(id: row.id))
    #expect(!FileManager.default.fileExists(atPath: onDisk))

    #expect(try await coordinator.updateExistingRow(cleaned) == false)
    #expect(coordinator.visibleTranscripts.isEmpty, "the deleted row came back on screen")
    #expect(!FileManager.default.fileExists(atPath: onDisk), "the deleted file was rewritten")
  }

  // MARK: - append(_:) contract

  @Test("append inserts at index 0")
  func testAppendInsertsAtIndexZero() async throws {
    let dir = Self.makeTempDir()
    defer { Self.cleanup(dir) }
    let store = TranscriptStore(directory: dir)
    let coordinator = TranscriptCoordinator(store: store)

    let first = Self.makeTranscript(text: "first")
    let second = Self.makeTranscript(text: "second")
    coordinator.append(first)
    coordinator.append(second)

    #expect(coordinator.visibleTranscripts.map(\.id) == [second.id, first.id])
  }

  @Test("append does not mutate disk")
  func testAppendDoesNotMutateDisk() async throws {
    let dir = Self.makeTempDir()
    defer { Self.cleanup(dir) }
    let store = TranscriptStore(directory: dir)
    let coordinator = TranscriptCoordinator(store: store)

    let before = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    coordinator.append(Self.makeTranscript())
    let after = try FileManager.default.contentsOfDirectory(atPath: dir.path)

    #expect(before == after)
  }

  // MARK: - Startup load regression

  @Test("startup load brings every on-disk row into memory")
  func testStartupLoadPreservesPreexisting() async throws {
    let dir = Self.makeTempDir()
    defer { Self.cleanup(dir) }
    let seeded = [
      Self.makeTranscript(text: "old-3", createdAt: Date().addingTimeInterval(-300)),
      Self.makeTranscript(text: "old-2", createdAt: Date().addingTimeInterval(-200)),
      Self.makeTranscript(text: "old-1", createdAt: Date().addingTimeInterval(-100)),
    ]
    try Self.writeToDisk(seeded, in: dir)
    let store = TranscriptStore(directory: dir)
    let coordinator = TranscriptCoordinator(store: store)

    coordinator.load()
    await coordinator.waitForLoadForTesting()

    #expect(coordinator.visibleTranscripts.count == 3)
    let loadedIDs = Set(coordinator.visibleTranscripts.map(\.id))
    let seededIDs = Set(seeded.map(\.id))
    #expect(loadedIDs == seededIDs)
  }

  // MARK: - Merge algorithm (race guard)

  // Save and append after the disk snapshot returns, before reconciliation. The snapshot
  // is certified but predates these writes, so their newer revision must preserve them. An
  // append before `load()` starts is not this race: its file is already on disk (`append`'s
  // precondition), so a complete read that lacks it means the file was deleted (#4075 G9).
  #if DEBUG
    @Test("load during a concurrent append merges both rows")
    func testLoadDuringAppendMergesCorrectly() async throws {
      let dir = Self.makeTempDir()
      defer { Self.cleanup(dir) }
      let diskOnly = Self.makeTranscript(text: "disk")
      try Self.writeToDisk([diskOnly], in: dir)
      let store = TranscriptStore(directory: dir)
      let coordinator = TranscriptCoordinator(store: store)

      let newRow = Self.makeTranscript(text: "appended")
      coordinator.historyReadDidFinishForTesting = { read in
        coordinator.historyReadDidFinishForTesting = nil
        #expect(read.freshness != nil)
        try store.save(newRow)
        coordinator.append(newRow)
      }
      coordinator.load()
      await coordinator.waitForLoadForTesting()

      let ids = coordinator.visibleTranscripts.map(\.id)
      #expect(ids.count == 2)
      #expect(ids.contains(newRow.id))
      #expect(ids.contains(diskOnly.id))
      // In-memory row must come before disk rows to preserve newest-first
      // under the append-order contract.
      #expect(ids.first == newRow.id)
    }

    /// Codex review of the #4075 S7 fix: a row written after the snapshot but OLDER than a
    /// row the snapshot found goes below it, by date, not in front of everything.
    @Test("load during an older row's write merges it by date")
    func testLoadDuringOlderWriteMergesByDate() async throws {
      let dir = Self.makeTempDir()
      defer { Self.cleanup(dir) }
      let now = Date()
      let diskRow = Self.makeTranscript(text: "disk", createdAt: now)
      try Self.writeToDisk([diskRow], in: dir)
      let store = TranscriptStore(directory: dir)
      let coordinator = TranscriptCoordinator(store: store)

      let older = Self.makeTranscript(text: "older", createdAt: now.addingTimeInterval(-60))
      coordinator.historyReadDidFinishForTesting = { read in
        coordinator.historyReadDidFinishForTesting = nil
        #expect(read.freshness != nil)
        try store.save(older)
        coordinator.append(older)
      }
      coordinator.load()
      await coordinator.waitForLoadForTesting()

      #expect(coordinator.visibleTranscripts.map(\.id) == [diskRow.id, older.id])
    }

    /// Codex review of the #4075 S7 fix: a row written during the read with the SAME date as
    /// a disk row stays ahead of it, as `append` put it, so Paste Last keeps its pick.
    @Test("load during a same-date write keeps the written row first")
    func testLoadDuringSameDateWriteKeepsItFirst() async throws {
      let dir = Self.makeTempDir()
      defer { Self.cleanup(dir) }
      let now = Date()
      let diskRow = Self.makeTranscript(text: "disk", createdAt: now)
      try Self.writeToDisk([diskRow], in: dir)
      let store = TranscriptStore(directory: dir)
      let coordinator = TranscriptCoordinator(store: store)

      let sameDate = Self.makeTranscript(text: "written", createdAt: now)
      coordinator.historyReadDidFinishForTesting = { read in
        coordinator.historyReadDidFinishForTesting = nil
        #expect(read.freshness != nil)
        try store.save(sameDate)
        coordinator.append(sameDate)
      }
      coordinator.load()
      await coordinator.waitForLoadForTesting()

      #expect(coordinator.visibleTranscripts.map(\.id) == [sameDate.id, diskRow.id])
    }

    /// Codex review of the #4075 S7 fix: a dictation dated before a newer row published
    /// lands below that row when it is appended.
    @Test("an append older than the newest row lands below it")
    func testOlderAppendLandsByDate() async throws {
      let dir = Self.makeTempDir()
      defer { Self.cleanup(dir) }
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let now = Date()
      let newer = Self.makeTranscript(text: "import", createdAt: now)
      try await coordinator.saveAndShow(newer)
      let older = Self.makeTranscript(text: "dictation", createdAt: now.addingTimeInterval(-5))
      coordinator.append(older)
      #expect(coordinator.visibleTranscripts.map(\.id) == [newer.id, older.id])
    }

    @Test("load during multiple appends preserves append-order at the front")
    func testLoadDuringMultipleAppendsPreservesNewestFirstOrder() async throws {
      let dir = Self.makeTempDir()
      defer { Self.cleanup(dir) }
      let diskRow = Self.makeTranscript(text: "disk")
      try Self.writeToDisk([diskRow], in: dir)
      let store = TranscriptStore(directory: dir)
      let coordinator = TranscriptCoordinator(store: store)

      // Three persisted appends after the snapshot, before reconciliation.
      let r1 = Self.makeTranscript(text: "r1")
      let r2 = Self.makeTranscript(text: "r2")
      let r3 = Self.makeTranscript(text: "r3")
      coordinator.historyReadDidFinishForTesting = { read in
        coordinator.historyReadDidFinishForTesting = nil
        #expect(read.freshness != nil)
        try store.save(r1)
        coordinator.append(r1)
        try store.save(r2)
        coordinator.append(r2)
        try store.save(r3)
        coordinator.append(r3)
      }
      coordinator.load()
      await coordinator.waitForLoadForTesting()

      // Pre-merge in-memory order was [r3, r2, r1] (each append inserts at 0).
      // After merge: in-memory rows first (order preserved), then disk row.
      let ids = coordinator.visibleTranscripts.map(\.id)
      #expect(ids == [r3.id, r2.id, r1.id, diskRow.id])
    }
  #endif

  // MARK: - Failed actions are shown (#4075 G10)

  @Test("a delete that fails is shown, keeps the row, and the message can be dismissed")
  func failedDeleteIsShown() async throws {
    let dir = Self.makeTempDir()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
      Self.cleanup(dir)
    }
    let row = Self.makeTranscript(text: "stays")
    try Self.writeToDisk([row], in: dir)
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    coordinator.load()
    await coordinator.waitForLoadForTesting()
    #expect(coordinator.actionFailure == nil)

    // #4075 S1: the presentation the failed removal must not touch.
    coordinator.selectedItemID = .transcript(row.id)
    coordinator.setShowEcho(true, rowID: row.id)
    var announced: [UUID] = []
    coordinator.onRowDeleted = { announced.append($0) }

    // A read-only folder: the file cannot be removed.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    await coordinator.delete(row)
    #expect(coordinator.actionFailure == .delete)
    #expect(coordinator.visibleTranscripts.map(\.id) == [row.id])
    #expect(coordinator.selectedItemID == .transcript(row.id), "a failed delete moved the selection")
    #expect(coordinator.isShowingEcho(rowID: row.id), "a failed delete cleared the echo choice")
    #expect(announced.isEmpty, "a failed delete was announced")

    coordinator.dismissActionFailure()
    #expect(coordinator.actionFailure == nil)
  }

  #if DEBUG
    @Test("a Delete All that fails is shown and changes nothing")
    func failedDeleteAllIsShown() async throws {
      let dir = Self.makeTempDir()
      defer { Self.cleanup(dir) }
      let row = Self.makeTranscript(text: "stays")
      try Self.writeToDisk([row], in: dir)
      let store = TranscriptStore(directory: dir)
      let coordinator = TranscriptCoordinator(store: store)
      coordinator.load()
      await coordinator.waitForLoadForTesting()

      store.deleteAllFaultsForTesting = [.handoff]
      await coordinator.deleteAll()
      #expect(coordinator.actionFailure == .deleteAll)
      #expect(coordinator.visibleTranscripts.map(\.id) == [row.id])
    }
  #endif

  @Test("a Keep that fails is shown and the recording stays held")
  func failedKeepIsShown() async throws {
    let dir = Self.makeTempDir()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
      Self.cleanup(dir)
    }
    let store = TranscriptStore(directory: dir)
    let now = Date()
    let held = Transcript(
      text: "held", createdAt: now, escapeRecoveredAt: now, escapeRecoveryTakeID: "TAKE-1")
    try store.savePending(held)
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.load()
    await coordinator.waitForLoadForTesting()

    // A read-only History folder: the permanent copy cannot be written.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    await coordinator.keep(held)
    #expect(coordinator.actionFailure == .keep)
    #expect(coordinator.visibleTranscripts.first?.escapeRecoveredAt != nil, "still held")
  }

  @Test("a successful delete shows no message")
  func successfulDeleteShowsNothing() async throws {
    let dir = Self.makeTempDir()
    defer { Self.cleanup(dir) }
    let row = Self.makeTranscript(text: "goes")
    try Self.writeToDisk([row], in: dir)
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    coordinator.load()
    await coordinator.waitForLoadForTesting()
    await coordinator.delete(row)
    #expect(coordinator.actionFailure == nil)
    #expect(coordinator.visibleTranscripts.isEmpty)
  }

  // MARK: - History Paste reads the row as it is now (#4075 R5)

  @Test("History Paste delivers the row's current text, not the copy taken at the press")
  func deliveryReadsTheCurrentRow() async throws {
    let dir = Self.makeTempDir()
    defer { Self.cleanup(dir) }
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    let raw = Self.makeTranscript(text: "raw words")
    try await coordinator.saveAndShow(raw)
    let pressed = raw  // the copy History Paste captured

    // An import's cleanup lands while History is hidden.
    let cleaned = Transcript(
      id: raw.id, text: "Cleaned words.", processingTime: 0.1, backendType: .parakeet,
      createdAt: raw.createdAt)
    #expect(try await coordinator.updateExistingRow(cleaned))
    #expect(coordinator.textForDelivery(pressed) == "Cleaned words.")

    // Deleted in that wait: nothing is delivered.
    await coordinator.delete(raw)
    #expect(coordinator.textForDelivery(pressed) == nil)
  }

  @Test("a dictation History never held keeps the text it showed")
  func deliveryOfAnUnheldDictation() {
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: Self.makeTempDir()))
    let live = Self.makeTranscript(text: "never saved")
    #expect(coordinator.textForDelivery(live) == "never saved")
  }

  // MARK: - Delete routing (consumer matrix row)

  @Test("delete removes from cache and disk")
  func testDeleteRemovesFromCacheAndDisk() async throws {
    let dir = Self.makeTempDir()
    defer { Self.cleanup(dir) }
    let row = Self.makeTranscript(text: "to-delete")
    try Self.writeToDisk([row], in: dir)
    let store = TranscriptStore(directory: dir)
    let coordinator = TranscriptCoordinator(store: store)
    coordinator.load()
    await coordinator.waitForLoadForTesting()

    await coordinator.delete(row)
    #expect(coordinator.visibleTranscripts.isEmpty)
    let onDisk = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0.hasSuffix(".json") }
    #expect(onDisk.isEmpty)
  }
}

/// #3972 R12, R19: when these fail, deleting a meeting in History leaves its audio on disk, a
/// meeting's row survives Delete All, or a meeting shows ready with a row a power cut can lose.
@MainActor
@Suite("TranscriptCoordinator with EnviousMeet", .tags(.productOutcome))
struct TranscriptCoordinatorMeetingTests {
  private static func makeTempDir() -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("meeting-rows-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("deleting a meeting row hands it to EnviousMeet, which removes the row itself")
  func meetingDeleteRoutes() async throws {
    let dir = Self.makeTempDir()
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    let meetingID = UUID()
    let meetingRow = Transcript(text: "standup", backendType: .parakeet, meetingID: meetingID)
    let dictation = Transcript(text: "a dictation", backendType: .parakeet)
    try await coordinator.saveAndShowDurably(meetingRow)
    try await coordinator.saveAndShow(dictation)
    var announced: [UUID] = []
    coordinator.onRowDeleted = { announced.append($0) }
    var handed: [UUID] = []
    coordinator.deleteMeeting = { handed.append($0) }

    await coordinator.delete(meetingRow)
    #expect(handed == [meetingID])
    #expect(coordinator.hasRow(id: meetingRow.id), "EnviousMeet removes it, in its own order")

    try await coordinator.removeRow(id: meetingRow.id)
    #expect(coordinator.hasRow(id: meetingRow.id) == false)
    #expect(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("\(meetingRow.id.uuidString).json").path) == false)
    // A row already gone (Delete All ran first) is not an error.
    try await coordinator.removeRow(id: meetingRow.id)
    #expect(announced.isEmpty)

    // Ordinary rows keep the ordinary delete.
    await coordinator.delete(dictation)
    #expect(coordinator.hasRow(id: dictation.id) == false)
    #expect(announced == [dictation.id])
  }

  @Test("Delete All marks every meeting before it empties the store")
  func deleteAllMarksMeetingsFirst() async throws {
    let dir = Self.makeTempDir()
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    let meetingID = UUID()
    let row = Transcript(text: "standup", backendType: .parakeet, meetingID: meetingID)
    try await coordinator.saveAndShowDurably(row)
    try await coordinator.saveAndShow(Transcript(text: "a dictation", backendType: .parakeet))
    let rowURL = dir.appendingPathComponent("\(row.id.uuidString).json")
    var rowExistedWhenMarked: Bool?
    var allowed = false
    coordinator.meetingsWillBeDeletedWithAll = { ids in
      #expect(ids == [meetingID])
      rowExistedWhenMarked = FileManager.default.fileExists(atPath: rowURL.path)
      return allowed
    }
    // A meeting that could not be marked: nothing is deleted.
    await coordinator.deleteAll()
    #expect(coordinator.actionFailure == .deleteAll)
    #expect(rowExistedWhenMarked == true)
    #expect(coordinator.listedCount == 2)
    #expect(FileManager.default.fileExists(atPath: rowURL.path))

    coordinator.dismissActionFailure()
    allowed = true
    await coordinator.deleteAll()
    #expect(coordinator.actionFailure == nil)
    #expect(coordinator.listedCount == 0)
  }

  #if DEBUG
    @Test("a rename while the row's durable write is held is refused; disk and list then match")
    func renameRefusedDuringDurableWrite() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let id = UUID()
      let turn = Turn(
        id: "t1", speakerId: "mic:1", startMs: 0, endMs: 900, originalTextRange: 0..<5)
      func row(_ text: String) -> Transcript {
        Transcript(
          id: id, text: text, backendType: .parakeet, speakerAnalysis: .labeled(count: 1),
          speakerNames: [:], turns: [turn], meetingID: UUID())
      }
      try await coordinator.saveAndShowDurably(row("first"))
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      coordinator.durableWriteWillStartForTesting = {
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
      }
      let write = Task { @MainActor in try await coordinator.saveAndShowDurably(row("second")) }
      #expect(await Task.detached { Self.waitBlocking(entered) }.value == .success)
      // Held and registered in flight: the rename is refused, the list is unchanged.
      let failure = await coordinator.renameSpeaker(
        id: id, speakerId: "mic:1", name: "Ana", isMeeting: true)
      #expect(failure != nil)
      #expect(coordinator.currentRow(id: id)?.text == "first")
      release.signal()
      try await write.value
      coordinator.durableWriteWillStartForTesting = nil
      let url = dir.appendingPathComponent("\(id.uuidString).json")
      let onDisk = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
      let listed = try #require(coordinator.currentRow(id: id))
      #expect(onDisk.text == "second")
      #expect(listed.text == "second")
      #expect(onDisk.speakerNames == listed.speakerNames)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
          .filter { $0.hasSuffix(".tmp") }.isEmpty)
      // Afterwards ordinary edits work again.
      await #expect(
        coordinator.renameSpeaker(id: id, speakerId: "mic:1", name: "Ana", isMeeting: true) == nil)
    }
  #endif

  #if DEBUG
    @Test("a held durable save leaves the main actor free, and the write runs off it")
    func heldDurableSaveLeavesMainActorFree() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let row = Transcript(text: "standup notes", backendType: .parakeet, meetingID: UUID())
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let releasedByTest = OSAllocatedUnfairLock<Bool?>(initialState: nil)
      defer { release.signal() }
      let ranOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
      coordinator.durableWriteWillStartForTesting = {
        ranOnMain.withLock { $0 = Thread.isMainThread }
        entered.signal()
        // deadline-fallback: bound a missing release; timeout must fail the test
        let outcome = release.wait(timeout: .now() + 10)
        releasedByTest.withLock { $0 = outcome == .success }
      }
      let write = Task { @MainActor in try await coordinator.saveAndShowDurably(row) }
      // This semaphore wait blocks: Task inherits MainActor, and a task group does
      // not offload blocking work. This local detached waiter is awaited immediately;
      // an @concurrent helper would add an unnecessary declaration for this test.
      try #require(await Task.detached { Self.waitBlocking(entered) }.value == .success)
      // The write is held on the worker; an independent main-actor action still completes.
      let other = Transcript(text: "dictated", backendType: .parakeet)
      coordinator.append(other)
      #expect(coordinator.hasRow(id: other.id))
      #expect(coordinator.hasRow(id: row.id) == false)
      release.signal()
      try await write.value
      #expect(releasedByTest.withLock { $0 } == true)
      coordinator.durableWriteWillStartForTesting = nil
      #expect(ranOnMain.withLock { $0 } == false)
      let onDisk = try JSONDecoder().decode(
        Transcript.self,
        from: Data(contentsOf: dir.appendingPathComponent("\(row.id.uuidString).json")))
      #expect(onDisk.text == "standup notes")
      #expect(coordinator.currentRow(id: row.id)?.text == "standup notes")
    }

    @Test("a durable save whose caller is cancelled after it starts still lands and shows")
    func cancelledDurableSaveStillSettles() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let row = Transcript(text: "standup notes", backendType: .parakeet, meetingID: UUID())
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let releasedByTest = OSAllocatedUnfairLock<Bool?>(initialState: nil)
      defer { release.signal() }
      coordinator.durableWriteWillStartForTesting = {
        entered.signal()
        // deadline-fallback: bound a missing release; timeout must fail the test
        let outcome = release.wait(timeout: .now() + 10)
        releasedByTest.withLock { $0 = outcome == .success }
      }
      let write = Task { @MainActor in try await coordinator.saveAndShowDurably(row) }
      // This semaphore wait blocks: Task inherits MainActor, and a task group does
      // not offload blocking work. This local detached waiter is awaited immediately;
      // an @concurrent helper would add an unnecessary declaration for this test.
      try #require(await Task.detached { Self.waitBlocking(entered) }.value == .success)
      write.cancel()
      release.signal()
      try await write.value
      #expect(releasedByTest.withLock { $0 } == true)
      coordinator.durableWriteWillStartForTesting = nil
      #expect(coordinator.currentRow(id: row.id)?.text == "standup notes")
      #expect(
        FileManager.default.fileExists(
          atPath: dir.appendingPathComponent("\(row.id.uuidString).json").path))
    }
  #endif

  @Test("a durable save the disk refuses keeps the shown row, reports the error, and frees the row")
  func failedDurableSaveKeepsShownRow() async throws {
    let dir = Self.makeTempDir()
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    let id = UUID()
    let meetingID = UUID()
    func row(_ text: String) -> Transcript {
      Transcript(id: id, text: text, backendType: .parakeet, meetingID: meetingID)
    }
    try await coordinator.saveAndShowDurably(row("first"))
    // A read-only folder: the write cannot create its temporary file.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    var failed = false
    do {
      try await coordinator.saveAndShowDurably(row("second"))
    } catch is TranscriptCoordinator.RowWriteInFlight {
      Issue.record("the refusal was the in-flight guard, not the disk")
    } catch {
      failed = true
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    #expect(failed)
    #expect(coordinator.currentRow(id: id)?.text == "first")
    let url = dir.appendingPathComponent("\(id.uuidString).json")
    #expect(try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url)).text == "first")
    // The row is no longer registered in flight: the next durable save lands.
    try await coordinator.saveAndShowDurably(row("third"))
    #expect(coordinator.currentRow(id: id)?.text == "third")
    #expect(try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url)).text == "third")
  }

  // MARK: - #4075 S1: one History transaction queue

  #if DEBUG
    /// Holds ordinary writes on the storage worker, one release per write. Counts the writes
    /// that reached the worker, so a test can tell one that started from one still queued.
    final class WorkerGate: Sendable {
      private let entered = DispatchSemaphore(value: 0)
      private let release = DispatchSemaphore(value: 0)
      private let started = OSAllocatedUnfairLock(initialState: 0)
      private let timedOut = OSAllocatedUnfairLock(initialState: false)
      /// Runs once per write, on the worker, before the write.
      let onStart: OSAllocatedUnfairLock<(@Sendable (Int) -> Void)?> = .init(initialState: nil)

      var startedCount: Int { started.withLock { $0 } }
      var anyTimedOut: Bool { timedOut.withLock { $0 } }

      func hook() {
        let number = started.withLock { $0 += 1; return $0 }
        onStart.withLock { $0 }?(number)
        entered.signal()
        // deadline-fallback: bound a missing release; a timeout fails the test
        if release.wait(timeout: .now() + 10) == .timedOut { timedOut.withLock { $0 = true } }
      }

      /// Waits off the main actor for the next write to reach the worker.
      func waitForStart() async -> Bool {
        // This semaphore wait blocks: Task inherits MainActor, and a task group does
        // not offload blocking work. This local detached waiter is awaited immediately;
        // an @concurrent helper would add an unnecessary declaration for this test.
        await Task.detached { [entered] in TranscriptCoordinatorMeetingTests.waitBlocking(entered) == .success }.value
      }

      func releaseOne() { release.signal() }
      func releaseAll() { for _ in 0..<8 { release.signal() } }
    }

    /// Codex History regrade 3, S7: an import's save held on the worker while a newer
    /// dictation arrives. The import lands below it, in date order, not on top.
    @Test("a held save that lands after a newer dictation shows below it")
    func heldSaveLandsInDateOrder() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      let now = Date()
      let older = Transcript(
        id: UUID(), text: "older", processingTime: 0.1, backendType: .parakeet,
        createdAt: now.addingTimeInterval(-60))
      let save = Task { @MainActor in try await coordinator.saveAndShow(older) }
      try #require(await gate.waitForStart(), "the save never reached the worker")
      let newer = Transcript(
        id: UUID(), text: "newer", processingTime: 0.1, backendType: .parakeet, createdAt: now)
      coordinator.append(newer)
      gate.releaseOne()
      try await save.value
      #expect(gate.anyTimedOut == false)
      #expect(coordinator.visibleTranscripts.map(\.id) == [newer.id, older.id])
    }

    @Test("a held History write leaves the main actor free and holds the next command back")
    func heldWriteHoldsTheNextCommand() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      let ranOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
      gate.onStart.withLock { $0 = { _ in ranOnMain.withLock { $0 = Thread.isMainThread } } }
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      let a = Transcript(text: "first", backendType: .parakeet)
      let b = Transcript(text: "second", backendType: .parakeet)
      let writeA = Task { @MainActor in try await coordinator.saveAndShow(a) }
      try #require(await gate.waitForStart(), "write A never reached the worker")
      let admittedBefore = coordinator.commandsAdmittedForTesting
      let writeB = Task { @MainActor in try await coordinator.saveAndShow(b) }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == admittedBefore + 1 },
        "write B was never admitted")
      // A is held on the worker: the main actor still runs, and B has not started.
      let other = Transcript(text: "dictated", backendType: .parakeet)
      coordinator.append(other)
      #expect(coordinator.hasRow(id: other.id))
      #expect(coordinator.hasRow(id: a.id) == false, "A was shown before its write landed")
      #expect(gate.startedCount == 1, "B started while A was still held")
      gate.releaseOne()
      try #require(await gate.waitForStart(), "write B never reached the worker")
      #expect(coordinator.hasRow(id: a.id), "A was not shown before B started")
      gate.releaseOne()
      try await writeA.value
      try await writeB.value
      #expect(ranOnMain.withLock { $0 } == false)
      #expect(gate.anyTimedOut == false)
      let fresh = try await TranscriptStore(directory: dir).loadAll()
      #expect(Set(fresh.map(\.id)) == [a.id, b.id])
      #expect(coordinator.currentRow(id: b.id)?.text == "second")
      #expect(coordinator.hasQueuedCommandsForTesting == false, "the drain did not go idle")
    }

    @Test("a cancelled caller's admitted write still lands, and a failed write does not stop the next")
    func cancelledAndFailedCommandsSettle() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      // Cancelled after admission: the write still lands and is shown.
      let kept = Transcript(text: "kept", backendType: .parakeet)
      let cancelled = Task { @MainActor in try await coordinator.saveAndShow(kept) }
      try #require(await gate.waitForStart(), "the write never reached the worker")
      cancelled.cancel()
      gate.releaseOne()
      try await cancelled.value
      #expect(coordinator.currentRow(id: kept.id)?.text == "kept")
      // A head that fails (read-only folder) settles with its error; the next command runs.
      let failing = Transcript(text: "refused", backendType: .parakeet)
      let next = Transcript(text: "next", backendType: .parakeet)
      gate.onStart.withLock {
        $0 = { number in
          let mode: Int16 = number == 2 ? 0o500 : 0o700
          try? FileManager.default.setAttributes(
            [.posixPermissions: mode], ofItemAtPath: dir.path)
        }
      }
      let failed = Task { @MainActor in try await coordinator.saveAndShow(failing) }
      try #require(await gate.waitForStart(), "the failing write never reached the worker")
      let following = Task { @MainActor in try await coordinator.saveAndShow(next) }
      gate.releaseOne()
      try #require(await gate.waitForStart(), "the next write never reached the worker")
      gate.releaseOne()
      await #expect(throws: (any Error).self) { try await failed.value }
      try await following.value
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
      #expect(coordinator.hasRow(id: failing.id) == false)
      #expect(coordinator.currentRow(id: next.id)?.text == "next")
      #expect(coordinator.hasQueuedCommandsForTesting == false)
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    @Test("Delete All waits for an earlier write, and a later save survives it")
    func deleteAllOrdersWithWrites() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      let earlier = Transcript(text: "earlier", backendType: .parakeet)
      let write = Task { @MainActor in try await coordinator.saveAndShow(earlier) }
      try #require(await gate.waitForStart(), "the earlier write never reached the worker")
      let admitted = coordinator.commandsAdmittedForTesting
      let deleteAll = Task { @MainActor in await coordinator.deleteAll() }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == admitted + 1 },
        "Delete All was never admitted")
      gate.releaseOne()
      try await write.value
      await deleteAll.value
      #expect(coordinator.hasRow(id: earlier.id) == false, "Delete All ran before the write")
      coordinator.ordinaryWriteWillStartForTesting = nil
      let later = Transcript(text: "later", backendType: .parakeet)
      try await coordinator.saveAndShow(later)
      let fresh = try await TranscriptStore(directory: dir).loadAll()
      #expect(fresh.map(\.id) == [later.id])
      #expect(try await coordinator.updateExistingRow(earlier) == false, "an update revived it")
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    /// #4075 S1: a scan that started before a write and finishes while that write is still
    /// on the worker. Its application is queued behind the write, so it cannot split the
    /// write's disk success from its publication, and the merge keeps the newer row.
    @Test("a scan that finishes while a write is on the worker applies after it, keeping the row")
    func scanFinishingDuringAWriteAppliesAfterIt() async throws {
      let dir = Self.makeTempDir()
      let store = TranscriptStore(directory: dir)
      let coordinator = TranscriptCoordinator(store: store)
      try await coordinator.saveAndShow(Transcript(text: "on disk", backendType: .parakeet))
      let scanEntered = DispatchSemaphore(value: 0)
      let scanRelease = DispatchSemaphore(value: 0)
      defer { scanRelease.signal() }
      let armed = OSAllocatedUnfairLock(initialState: true)
      let scanReleased = OSAllocatedUnfairLock<Bool?>(initialState: nil)
      store.permanentFileWillReadForTesting = {
        guard armed.withLock({ let was = $0; $0 = false; return was }) else { return }
        scanEntered.signal()
        // deadline-fallback: bound a missing release; a timeout fails the test below
        let outcome = scanRelease.wait(timeout: .now() + 10)
        scanReleased.withLock { $0 = outcome == .success }
      }
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.load()
      // This semaphore wait blocks: Task inherits MainActor, and a task group does
      // not offload blocking work. This local detached waiter is awaited immediately;
      // an @concurrent helper would add an unnecessary declaration for this test.
      try #require(
        await Task.detached { Self.waitBlocking(scanEntered) == .success }.value,
        "the scan never started")
      // The scan is under way; now a write starts and is held on the worker.
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      let row = Transcript(text: "written during the scan", backendType: .parakeet)
      let write = Task { @MainActor in try await coordinator.saveAndShow(row) }
      try #require(await gate.waitForStart(), "the write never reached the worker")
      let admitted = coordinator.commandsAdmittedForTesting
      scanRelease.signal()
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == admitted + 1 },
        "the scan's application was never queued")
      #expect(coordinator.hasRow(id: row.id) == false, "the write was shown before it landed")
      gate.releaseOne()
      try await write.value
      await coordinator.waitForLoadForTesting()
      #expect(coordinator.rawTranscriptsForTesting.filter { $0.id == row.id }.count == 1)
      #expect(coordinator.currentRow(id: row.id)?.text == "written during the scan")
      #expect(scanReleased.withLock { $0 } == true, "the scan was released by its timeout")
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    @Test("a caller cancelled while its write waits behind another still has it land")
    func cancelledBeforeTheWorkerStillLands() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      let first = Transcript(text: "first", backendType: .parakeet)
      let queued = Transcript(text: "queued", backendType: .parakeet)
      let a = Task { @MainActor in try await coordinator.saveAndShow(first) }
      try #require(await gate.waitForStart(), "write A never reached the worker")
      let admitted = coordinator.commandsAdmittedForTesting
      let b = Task { @MainActor in try await coordinator.saveAndShow(queued) }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == admitted + 1 })
      b.cancel()
      gate.releaseOne()
      try #require(await gate.waitForStart(), "the cancelled caller's write was withdrawn")
      gate.releaseOne()
      try await a.value
      try await b.value
      #expect(coordinator.currentRow(id: queued.id)?.text == "queued")
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    @Test("a cleaned update keeps a rename queued before it, and an import rename uses the row as it is then")
    func semanticUpdatesKeepWhatEarlierCommandsLeft() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let turn = Turn(id: "t1", speakerId: "mic:1", startMs: 0, endMs: 900, originalTextRange: 0..<5)
      let raw = Transcript(
        text: "hello", backendType: .parakeet, speakerAnalysis: .labeled(count: 1),
        speakerNames: [:], turns: [turn])
      try await coordinator.saveAndShow(raw)
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      // A History rename is admitted first and held; the cleaned update, built from the raw
      // row without the name, is admitted behind it.
      let rename = Task { @MainActor in
        await coordinator.renameSpeaker(id: raw.id, speakerId: "mic:1", name: "Ana", isMeeting: false)
      }
      try #require(await gate.waitForStart(), "the rename never reached the worker")
      let admitted = coordinator.commandsAdmittedForTesting
      let cleaned = raw.withImportResult(
        "Hello.", wasPolished: true, llmProvider: "openai", llmModel: "m")
      let update = Task { @MainActor in try await coordinator.updateExistingRow(cleaned) }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == admitted + 1 })
      gate.releaseOne()
      try #require(await gate.waitForStart(), "the cleaned update never reached the worker")
      gate.releaseOne()
      #expect(await rename.value == nil)
      #expect(try await update.value)
      let row = try #require(coordinator.currentRow(id: raw.id))
      #expect(row.speakerNames?["mic:1"] == "Ana", "the cleaned update reverted the rename")
      #expect(row.polishedText == "Hello.")

      // An import rename sends turns read before a speaker merge; it renames on the merged turns.
      let newTurn = Turn(
        id: "t2", speakerId: "mic:1", startMs: 0, endMs: 1200, originalTextRange: 0..<5)
      let merge = Task { @MainActor in
        try await coordinator.mergeSpeakerFields(
          id: raw.id, analysis: .labeled(count: 1), turns: [newTurn])
      }
      try #require(await gate.waitForStart(), "the merge never reached the worker")
      let admittedRename = coordinator.commandsAdmittedForTesting
      let importRename = Task { @MainActor in
        try await coordinator.mergeSpeakerFields(
          id: raw.id, analysis: .labeled(count: 1), turns: [turn],
          explicitRename: ("mic:1", "Bea"))
      }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == admittedRename + 1 })
      gate.releaseOne()
      try #require(await gate.waitForStart(), "the import rename never reached the worker")
      gate.releaseOne()
      #expect(try await merge.value)
      #expect(try await importRename.value)
      let renamed = try #require(coordinator.currentRow(id: raw.id))
      #expect(renamed.turns?.map(\.id) == ["t2"], "the rename put back turns read before the merge")
      #expect(renamed.speakerNames?["mic:1"] == "Bea")
      #expect(gate.anyTimedOut == false)
    }

    @Test("an ordinary write admitted before a durable one stays valid; one admitted after is refused")
    func ordinaryAndDurableAdmissionOrders() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let id = UUID()
      let meetingID = UUID()
      func row(_ text: String) -> Transcript {
        Transcript(id: id, text: text, backendType: .parakeet, meetingID: meetingID)
      }
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      // Ordinary first, held; the durable write is admitted behind it and lands last.
      let ordinary = Task { @MainActor in try await coordinator.saveAndShow(row("ordinary")) }
      try #require(await gate.waitForStart(), "the ordinary write never reached the worker")
      let admitted = coordinator.commandsAdmittedForTesting
      let durable = Task { @MainActor in try await coordinator.saveAndShowDurably(row("durable")) }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == admitted + 1 },
        "the durable write was never admitted")
      // Admitted after the durable write: refused at once.
      await #expect(throws: TranscriptCoordinator.RowWriteInFlight.self) {
        try await coordinator.saveAndShow(row("late"))
      }
      gate.releaseOne()
      try await ordinary.value
      try await durable.value
      let onDisk = try JSONDecoder().decode(
        Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).json")))
      #expect(onDisk.text == "durable")
      #expect(coordinator.currentRow(id: id)?.text == "durable")
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    @Test("a deletion is announced before a re-insertion queued behind it runs")
    func deletionAnnouncedBeforeTheNextCommand() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let row = Transcript(text: "row", backendType: .parakeet)
      try await coordinator.saveAndShow(row)
      let announced = OSAllocatedUnfairLock(initialState: false)
      coordinator.onRowDeleted = { _ in announced.withLock { $0 = true } }
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      let announcedAtReinsert = OSAllocatedUnfairLock<Bool?>(initialState: nil)
      gate.onStart.withLock {
        $0 = { number in
          if number == 2 { announcedAtReinsert.withLock { $0 = announced.withLock { $0 } } }
        }
      }
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      // An unrelated write holds the head, so the order of the two below is their admission.
      let head = Task { @MainActor in
        try await coordinator.saveAndShow(Transcript(text: "head", backendType: .parakeet))
      }
      try #require(await gate.waitForStart(), "the head never reached the worker")
      let beforeDelete = coordinator.commandsAdmittedForTesting
      let delete = Task { @MainActor in await coordinator.delete(row) }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == beforeDelete + 1 },
        "the delete was never admitted")
      let reinsert = Task { @MainActor in try await coordinator.saveAndShow(row) }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == beforeDelete + 2 },
        "the re-insertion was never admitted")
      gate.releaseOne()
      try #require(await gate.waitForStart(), "the re-insertion never reached the worker")
      gate.releaseOne()
      try await head.value
      await delete.value
      try await reinsert.value
      #expect(announcedAtReinsert.withLock { $0 } == true, "the re-insertion ran before the announcement")
      #expect(coordinator.hasRow(id: row.id))
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    @Test("a History rename queued behind a delete of its row says the recording was removed")
    func renameQueuedBehindDeleteIsRemoved() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let turn = Turn(id: "t1", speakerId: "mic:1", startMs: 0, endMs: 900, originalTextRange: 0..<5)
      let row = Transcript(
        text: "hello", backendType: .parakeet, speakerAnalysis: .labeled(count: 1),
        speakerNames: [:], turns: [turn])
      try await coordinator.saveAndShow(row)
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      let head = Task { @MainActor in
        try await coordinator.saveAndShow(Transcript(text: "head", backendType: .parakeet))
      }
      try #require(await gate.waitForStart(), "the head never reached the worker")
      let before = coordinator.commandsAdmittedForTesting
      let delete = Task { @MainActor in await coordinator.delete(row) }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 1 })
      let rename = Task { @MainActor in
        await coordinator.renameSpeaker(id: row.id, speakerId: "mic:1", name: "Ana", isMeeting: false)
      }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 2 })
      gate.releaseOne()
      try await head.value
      await delete.value
      #expect(await rename.value?.message == RenameFailure.recordingRemoved)
      #expect(coordinator.hasRow(id: row.id) == false, "the rename wrote the row back")
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    @Test("a command's result is kept when it finishes before anyone asks for it")
    func receiptKeepsAResultCompletedBeforeTheWaiter() async throws {
      let receipt = TranscriptCoordinator.Receipt<Int>()
      receipt.complete(42)
      var read: Int?
      let reader = Task { @MainActor in read = await receipt.result() }
      try #require(await settleUntilObserved { read != nil }, "the kept result was never returned")
      await reader.value
      #expect(read == 42)
    }

    @Test("a read whose application is queued and then replaced publishes nothing")
    func supersededQueuedApplicationPublishesNothing() async throws {
      let dir = Self.makeTempDir()
      let store = TranscriptStore(directory: dir)
      let coordinator = TranscriptCoordinator(store: store)
      try await coordinator.saveAndShow(Transcript(text: "on disk", backendType: .parakeet))
      let scanEntered = DispatchSemaphore(value: 0)
      let scanRelease = DispatchSemaphore(value: 0)
      defer { scanRelease.signal() }
      let armed = OSAllocatedUnfairLock(initialState: true)
      let scanReleased = OSAllocatedUnfairLock<Bool?>(initialState: nil)
      store.permanentFileWillReadForTesting = {
        guard armed.withLock({ let was = $0; $0 = false; return was }) else { return }
        scanEntered.signal()
        // deadline-fallback: bound a missing release; a timeout fails the test below
        let outcome = scanRelease.wait(timeout: .now() + 10)
        scanReleased.withLock { $0 = outcome == .success }
      }
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.load()
      // This semaphore wait blocks: Task inherits MainActor, and a task group does
      // not offload blocking work. This local detached waiter is awaited immediately;
      // an @concurrent helper would add an unnecessary declaration for this test.
      try #require(
        await Task.detached { Self.waitBlocking(scanEntered) == .success }.value,
        "the scan never started")
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      let write = Task { @MainActor in
        try await coordinator.saveAndShow(Transcript(text: "held", backendType: .parakeet))
      }
      try #require(await gate.waitForStart(), "the write never reached the worker")
      let admitted = coordinator.commandsAdmittedForTesting
      scanRelease.signal()
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == admitted + 1 },
        "the first read's application was never queued")
      let readsBefore = coordinator.historyFullReadsForTesting
      let endsBefore = coordinator.historyReadEndsForTesting
      // A newer read replaces the queued one before it runs.
      coordinator.load()
      coordinator.ordinaryWriteWillStartForTesting = nil
      gate.releaseOne()
      try await write.value
      await coordinator.waitForLoadForTesting()
      #expect(
        coordinator.historyFullReadsForTesting == readsBefore + 1,
        "the replaced read published as well as its replacement")
      #expect(coordinator.historyReadEndsForTesting == endsBefore + 1)
      #expect(scanReleased.withLock { $0 } == true, "the scan was released by its timeout")
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    @Test("Delete All admitted after a write's file landed and before it is shown removes it")
    func deleteAllAfterDiskBeforePublication() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.ordinaryWriteDidFinishForTesting = { gate.hook() }
      let row = Transcript(text: "landed", backendType: .parakeet)
      let write = Task { @MainActor in try await coordinator.saveAndShow(row) }
      try #require(await gate.waitForStart(), "the write's file never landed")
      #expect(
        FileManager.default.fileExists(
          atPath: dir.appendingPathComponent("\(row.id.uuidString).json").path))
      #expect(coordinator.hasRow(id: row.id) == false)
      let admitted = coordinator.commandsAdmittedForTesting
      let deleteAll = Task { @MainActor in await coordinator.deleteAll() }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == admitted + 1 },
        "Delete All was never admitted")
      gate.releaseOne()
      try await write.value
      await deleteAll.value
      #expect(coordinator.hasRow(id: row.id) == false)
      #expect(try await TranscriptStore(directory: dir).loadAll().isEmpty)
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    @Test("a speaker merge keeps a rename queued before it, and a rename keeps a cleaned update before it")
    func otherOrderingDirectionsKeepTheirFields() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let turn = Turn(id: "t1", speakerId: "mic:1", startMs: 0, endMs: 900, originalTextRange: 0..<5)
      let raw = Transcript(
        text: "hello", backendType: .parakeet, speakerAnalysis: .labeled(count: 1),
        speakerNames: [:], turns: [turn])
      try await coordinator.saveAndShow(raw)
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      // Rename first (held), then a background speaker merge: the name survives the merge.
      let rename = Task { @MainActor in
        await coordinator.renameSpeaker(id: raw.id, speakerId: "mic:1", name: "Ana", isMeeting: false)
      }
      try #require(await gate.waitForStart(), "the rename never reached the worker")
      let newTurn = Turn(
        id: "t2", speakerId: "mic:1", startMs: 0, endMs: 1200, originalTextRange: 0..<5)
      let admitted = coordinator.commandsAdmittedForTesting
      let merge = Task { @MainActor in
        try await coordinator.mergeSpeakerFields(
          id: raw.id, analysis: .labeled(count: 1), turns: [newTurn])
      }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == admitted + 1 })
      gate.releaseOne()
      try #require(await gate.waitForStart(), "the merge never reached the worker")
      gate.releaseOne()
      #expect(await rename.value == nil)
      #expect(try await merge.value)
      let merged = try #require(coordinator.currentRow(id: raw.id))
      #expect(merged.speakerNames?["mic:1"] == "Ana", "the merge dropped the rename")
      #expect(merged.turns?.map(\.id) == ["t2"])
      #expect(merged.text == "hello")

      // Cleaned update first (held), then a rename: the rename keeps the cleaned text and credit.
      let cleaned = merged.withImportResult(
        "Hello.", wasPolished: true, llmProvider: "openai", llmModel: "m")
      let update = Task { @MainActor in try await coordinator.updateExistingRow(cleaned) }
      try #require(await gate.waitForStart(), "the cleaned update never reached the worker")
      let admittedRename = coordinator.commandsAdmittedForTesting
      let rename2 = Task { @MainActor in
        await coordinator.renameSpeaker(id: raw.id, speakerId: "mic:1", name: "Bea", isMeeting: false)
      }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == admittedRename + 1 })
      gate.releaseOne()
      try #require(await gate.waitForStart(), "the second rename never reached the worker")
      gate.releaseOne()
      #expect(try await update.value)
      #expect(await rename2.value == nil)
      let final = try #require(coordinator.currentRow(id: raw.id))
      #expect(final.polishedText == "Hello.", "the rename reverted the cleaned text")
      #expect(final.llmProvider == "openai")
      #expect(final.speakerNames?["mic:1"] == "Bea")
      #expect(final.turns?.map(\.id) == ["t2"])
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    /// #4075 S1: Keep and the expiry sweep share the queue. A sweep that runs first removes
    /// the lapsed row, so a Keep behind it is refused and writes nothing; a Keep that runs
    /// first promotes the row, and a sweep behind it leaves the kept row alone.
    @Test("Keep and the expiry sweep, in either order, never keep a lapsed row or drop a kept one")
    func keepAndSweepInEitherOrder() async throws {
      for sweepFirst in [true, false] {
        let dir = Self.makeTempDir()
        let store = TranscriptStore(directory: dir)
        var kept = 0
        var outcomes: [String] = []
        let coordinator = TranscriptCoordinator(
          store: store, emitEscapeRecoveryKept: { _, _ in kept += 1 },
          recordEscapeRecoveryKeep: { outcome, _ in outcomes.append(outcome) })
        let stamp = Date().addingTimeInterval(-60)
        let held = Transcript(text: "held", escapeRecoveredAt: stamp, escapeRecoveryTakeID: "take")
        try store.savePending(held)
        coordinator.load()
        await coordinator.waitForLoadForTesting()
        let loaded = try #require(coordinator.currentRow(id: held.id))
        let lapsed = stamp.addingTimeInterval(AppConstants.pendingTranscriptRetention + 60)
        coordinator.clockForTesting = { sweepFirst ? lapsed : Date() }
        let gate = WorkerGate()
        defer { gate.releaseAll() }
        coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
        let head = Task { @MainActor in
          try await coordinator.saveAndShow(Transcript(text: "head", backendType: .parakeet))
        }
        try #require(await gate.waitForStart(), "the head never reached the worker")
        let before = coordinator.commandsAdmittedForTesting
        let first: Task<Void, Never>
        let second: Task<Void, Never>
        if sweepFirst {
          first = Task { @MainActor in await coordinator.sweepExpiredPending(now: lapsed) }
          try #require(
            await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 1 })
          second = Task { @MainActor in await coordinator.keep(loaded) }
        } else {
          first = Task { @MainActor in await coordinator.keep(loaded) }
          try #require(
            await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 1 })
          second = Task { @MainActor in await coordinator.sweepExpiredPending(now: lapsed) }
        }
        try #require(
          await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 2 })
        gate.releaseOne()
        try await head.value
        await first.value
        await second.value
        let permanent = try await TranscriptStore(directory: dir).loadAll()
        if sweepFirst {
          #expect(outcomes == ["refused-not-offerable"], "a lapsed row was kept")
          #expect(kept == 0)
          #expect(coordinator.currentRow(id: held.id) == nil)
          #expect(permanent.contains { $0.id == held.id } == false)
        } else {
          #expect(outcomes == ["kept"])
          #expect(kept == 1)
          #expect(coordinator.currentRow(id: held.id)?.escapeRecoveredAt == nil, "the sweep dropped it")
          #expect(permanent.contains { $0.id == held.id })
        }
        #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
      }
    }

    @Test("Keep is judged at its run time, and its kept event's age runs to the press")
    func keepUsesExecutionTimeForEligibilityAndPressTimeForAge() async throws {
      for (pressAfter, runAfter, promotes) in [
        (TimeInterval(3_600), TimeInterval(7_200), true),
        (AppConstants.pendingTranscriptRetention - 60, AppConstants.pendingTranscriptRetention + 60, false),
      ] {
        let dir = Self.makeTempDir()
        let store = TranscriptStore(directory: dir)
        var kept: [Int] = []
        var outcomes: [String] = []
        let coordinator = TranscriptCoordinator(
          store: store, emitEscapeRecoveryKept: { age, _ in kept.append(age) },
          recordEscapeRecoveryKeep: { outcome, _ in outcomes.append(outcome) })
        let stamp = Date().addingTimeInterval(-60)
        let held = Transcript(
          text: "held", escapeRecoveredAt: stamp, escapeRecoveryTakeID: "take")
        try store.savePending(held)
        coordinator.load()
        await coordinator.waitForLoadForTesting()
        let loaded = try #require(coordinator.currentRow(id: held.id))
        // A held write ahead of Keep separates the press from the run.
        let gate = WorkerGate()
        defer { gate.releaseAll() }
        coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
        let blocker = Task { @MainActor in
          try await coordinator.saveAndShow(Transcript(text: "blocker", backendType: .parakeet))
        }
        try #require(await gate.waitForStart(), "the blocker never reached the worker")
        var clock = stamp.addingTimeInterval(pressAfter)
        coordinator.clockForTesting = { clock }
        let admitted = coordinator.commandsAdmittedForTesting
        let keep = Task { @MainActor in await coordinator.keep(loaded) }
        try #require(
          await settleUntilObserved { coordinator.commandsAdmittedForTesting == admitted + 1 },
          "Keep was never admitted")
        clock = stamp.addingTimeInterval(runAfter)
        gate.releaseOne()
        try await blocker.value
        await keep.value
        if promotes {
          #expect(outcomes == ["kept"])
          #expect(kept.count == 1)
          #expect(abs((kept.first ?? 0) - Int(pressAfter * 1000)) < 1_000, "age ran to the run")
          #expect(coordinator.currentRow(id: held.id)?.escapeRecoveredAt == nil)
        } else {
          #expect(outcomes == ["refused-not-offerable"], "an expired row was kept")
          #expect(kept.isEmpty)
        }
        #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
      }
    }
  #endif

  @Test("a second Delete of the same row is a no-op: one announcement, nothing else changes")
  func duplicateDeleteAnnouncesOnce() async throws {
    let dir = Self.makeTempDir()
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    var announced: [UUID] = []
    coordinator.onRowDeleted = { announced.append($0) }
    let row = Transcript(text: "delete me", backendType: .parakeet)
    try await coordinator.saveAndShow(row)
    let first = Task { @MainActor in await coordinator.delete(row) }
    let second = Task { @MainActor in await coordinator.delete(row) }
    await first.value
    await second.value
    #expect(announced == [row.id])
    #expect(coordinator.actionFailure == nil)
    // Written back and deleted again: a new removal, announced again.
    try await coordinator.saveAndShow(row)
    await coordinator.delete(row)
    #expect(announced == [row.id, row.id])
  }

  #if DEBUG
    // MARK: - #4075 S1: remaining queue windows (plan-to-evidence audit)

    @Test("a successful delete moves the selection to the row beside it and clears its echo choice")
    func successfulDeleteMovesSelectionAndClearsEcho() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let older = Transcript(text: "older", backendType: .parakeet, createdAt: Date().addingTimeInterval(-60))
      let newer = Transcript(text: "newer", backendType: .parakeet)
      try await coordinator.saveAndShow(older)
      try await coordinator.saveAndShow(newer)
      coordinator.selectedItemID = .transcript(newer.id)
      coordinator.setShowEcho(true, rowID: newer.id)
      await coordinator.delete(newer)
      #expect(coordinator.selectedItemID == .transcript(older.id), "the neighbour was not selected")
      #expect(coordinator.isShowingEcho(rowID: newer.id) == false)
      // A second delete of the gone row is a no-op: the selection stays where it moved.
      await coordinator.delete(newer)
      #expect(coordinator.selectedItemID == .transcript(older.id))
      #expect(coordinator.actionFailure == nil)
    }

    @Test("a selection, search or filter chosen while a write waits survives the write")
    func choicesMadeWhileAWriteWaitsSurvive() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let first = Transcript(text: "first zebra", backendType: .parakeet)
      let second = Transcript(text: "second zebra", backendType: .parakeet)
      try await coordinator.saveAndShow(first)
      try await coordinator.saveAndShow(second)
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      let edited = Transcript(id: first.id, text: "first zebra edited", backendType: .parakeet, createdAt: first.createdAt)
      let write = Task { @MainActor in try await coordinator.updateExistingRow(edited) }
      try #require(await gate.waitForStart(), "the write never reached the worker")
      coordinator.selectedItemID = .transcript(second.id)
      coordinator.searchQuery = "zebra"
      coordinator.historyFilter = .dictations
      gate.releaseOne()
      #expect(try await write.value)
      #expect(coordinator.selectedItemID == .transcript(second.id), "the write restored an old selection")
      #expect(coordinator.searchQuery == "zebra")
      #expect(coordinator.historyFilter == .dictations)
      #expect(coordinator.currentRow(id: first.id)?.text == "first zebra edited")
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    @Test("a Keep queued behind a delete of its row is refused and writes nothing back")
    func staleKeepAfterDeleteIsRefused() async throws {
      let dir = Self.makeTempDir()
      let store = TranscriptStore(directory: dir)
      var kept = 0
      var outcomes: [String] = []
      let coordinator = TranscriptCoordinator(
        store: store, emitEscapeRecoveryKept: { _, _ in kept += 1 },
        recordEscapeRecoveryKeep: { outcome, _ in outcomes.append(outcome) })
      let held = Transcript(
        text: "held", escapeRecoveredAt: Date().addingTimeInterval(-60), escapeRecoveryTakeID: "take")
      try store.savePending(held)
      coordinator.load()
      await coordinator.waitForLoadForTesting()
      let loaded = try #require(coordinator.currentRow(id: held.id))
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      let head = Task { @MainActor in
        try await coordinator.saveAndShow(Transcript(text: "head", backendType: .parakeet))
      }
      try #require(await gate.waitForStart(), "the head never reached the worker")
      let before = coordinator.commandsAdmittedForTesting
      let delete = Task { @MainActor in await coordinator.delete(loaded) }
      try #require(await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 1 })
      let keep = Task { @MainActor in await coordinator.keep(loaded) }
      try #require(await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 2 })
      gate.releaseOne()
      try await head.value
      await delete.value
      await keep.value
      #expect(outcomes == ["refused-not-offerable"])
      #expect(kept == 0)
      #expect(coordinator.currentRow(id: held.id) == nil)
      #expect(try await TranscriptStore(directory: dir).loadAll().contains { $0.id == held.id } == false)
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    @Test("an update queued before a delete lands then goes; one queued after refuses; a save behind Delete All survives")
    func queuedUpdateDeleteAndDeleteAllOrders() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let row = Transcript(text: "row", backendType: .parakeet)
      try await coordinator.saveAndShow(row)
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      let head = Task { @MainActor in
        try await coordinator.saveAndShow(Transcript(text: "head", backendType: .parakeet))
      }
      try #require(await gate.waitForStart(), "the head never reached the worker")
      let before = coordinator.commandsAdmittedForTesting
      let edited = Transcript(id: row.id, text: "edited", backendType: .parakeet, createdAt: row.createdAt)
      let updateFirst = Task { @MainActor in try await coordinator.updateExistingRow(edited) }
      try #require(await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 1 })
      let delete = Task { @MainActor in await coordinator.delete(row) }
      try #require(await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 2 })
      let updateAfter = Task { @MainActor in try await coordinator.updateExistingRow(edited) }
      try #require(await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 3 })
      let deleteAll = Task { @MainActor in await coordinator.deleteAll() }
      try #require(await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 4 })
      let survivor = Transcript(text: "survivor", backendType: .parakeet)
      let late = Task { @MainActor in try await coordinator.saveAndShow(survivor) }
      try #require(await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 5 })
      gate.releaseAll()
      try await head.value
      #expect(try await updateFirst.value, "the update admitted before the delete did not land")
      await delete.value
      #expect(try await updateAfter.value == false, "an update after the delete revived the row")
      await deleteAll.value
      try await late.value
      #expect(coordinator.hasRow(id: row.id) == false)
      let fresh = try await TranscriptStore(directory: dir).loadAll()
      #expect(fresh.map(\.id) == [survivor.id], "a save admitted behind Delete All was lost")
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    /// #4075 S1: a scan whose snapshot holds a row, and a delete of that row that commits
    /// before the snapshot is applied. The stale snapshot must not bring the row back: the
    /// removal moved the disk generation, so a fresh read replaces it.
    @Test("a scan that read a row before its delete committed does not bring the row back")
    func readSpanningACommittedDeleteDoesNotResurrect() async throws {
      let dir = Self.makeTempDir()
      let store = TranscriptStore(directory: dir)
      let coordinator = TranscriptCoordinator(store: store)
      let row = Transcript(text: "deleted mid-read", backendType: .parakeet)
      try await coordinator.saveAndShow(row)
      let scanEntered = DispatchSemaphore(value: 0)
      let scanRelease = DispatchSemaphore(value: 0)
      defer { scanRelease.signal() }
      let armed = OSAllocatedUnfairLock(initialState: true)
      let scanReleased = OSAllocatedUnfairLock<Bool?>(initialState: nil)
      store.permanentFileWillReadForTesting = {
        guard armed.withLock({ let was = $0; $0 = false; return was }) else { return }
        scanEntered.signal()
        // deadline-fallback: bound a missing release; a timeout fails the test below
        let outcome = scanRelease.wait(timeout: .now() + 10)
        scanReleased.withLock { $0 = outcome == .success }
      }
      var snapshotHeldRow: Bool?
      coordinator.historyReadDidFinishForTesting = { read in
        if snapshotHeldRow == nil { snapshotHeldRow = read.permanent.contains { $0.id == row.id } }
      }
      let gate = WorkerGate()
      defer { gate.releaseAll() }
      let readsBefore = coordinator.historyFullReadsForTesting
      coordinator.load()
      // This semaphore wait blocks: Task inherits MainActor, and a task group does
      // not offload blocking work. This local detached waiter is awaited immediately;
      // an @concurrent helper would add an unnecessary declaration for this test.
      try #require(
        await Task.detached { Self.waitBlocking(scanEntered) == .success }.value,
        "the scan never started")
      // A write holds the queue's head; the delete is admitted behind it, before the scan ends.
      coordinator.ordinaryWriteWillStartForTesting = { gate.hook() }
      let head = Task { @MainActor in
        try await coordinator.saveAndShow(Transcript(text: "head", backendType: .parakeet))
      }
      try #require(await gate.waitForStart(), "the head never reached the worker")
      let before = coordinator.commandsAdmittedForTesting
      let delete = Task { @MainActor in await coordinator.delete(row) }
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 1 },
        "the delete was never admitted")
      // The scan now reads the row's file and queues its application behind the delete.
      scanRelease.signal()
      try #require(
        await settleUntilObserved { coordinator.commandsAdmittedForTesting == before + 2 },
        "the scan's application was never queued")
      #expect(snapshotHeldRow == true, "the scan's snapshot did not hold the row")
      coordinator.ordinaryWriteWillStartForTesting = nil
      gate.releaseOne()
      try await head.value
      await delete.value
      await coordinator.waitForLoadForTesting()
      #expect(coordinator.hasRow(id: row.id) == false, "the stale scan brought the deleted row back")
      #expect(
        coordinator.historyFullReadsForTesting == readsBefore + 1,
        "the stale read published, or no fresh read replaced it")
      #expect(coordinator.hasQueuedCommandsForTesting == false, "the queue did not go idle")
      #expect(scanReleased.withLock { $0 } == true, "the scan was released by its timeout")
      #expect(gate.anyTimedOut == false, "a held write was released by its timeout")
    }

    @Test("a caller already cancelled before it reaches History submits nothing")
    func cancelledBeforeAdmissionSubmitsNothing() async throws {
      let dir = Self.makeTempDir()
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      let row = Transcript(text: "never", backendType: .parakeet)
      let admitted = coordinator.commandsAdmittedForTesting
      // Not yet started: this test holds the main actor until it awaits the task.
      let save = Task { @MainActor in try await coordinator.saveAndShow(row) }
      save.cancel()
      await #expect(throws: CancellationError.self) { try await save.value }
      #expect(coordinator.commandsAdmittedForTesting == admitted)
      #expect(coordinator.hasRow(id: row.id) == false)
    }
  #endif

  nonisolated static func waitBlocking(_ semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + 10)
  }

  @Test("a durable save writes the same row a plain save does, then shows it")
  func durableSaveRoundTrips() async throws {
    let dir = Self.makeTempDir()
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    let row = Transcript(text: "standup notes", backendType: .parakeet, meetingID: UUID())
    try await coordinator.saveAndShowDurably(row)
    #expect(coordinator.hasRow(id: row.id))
    let data = try Data(contentsOf: dir.appendingPathComponent("\(row.id.uuidString).json"))
    let decoded = try JSONDecoder().decode(Transcript.self, from: data)
    #expect(decoded.id == row.id)
    #expect(decoded.meetingID == row.meetingID)
    #expect(decoded.text == "standup notes")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasSuffix(".tmp") }.isEmpty)
  }
}
