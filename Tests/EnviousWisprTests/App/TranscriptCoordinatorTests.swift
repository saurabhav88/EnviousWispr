import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

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
    let url = FileManager.default.temporaryDirectory
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
  func anImportCountsAsARowNotADictation() throws {
    let dir = Self.makeTempDir()
    defer { Self.cleanup(dir) }
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    try coordinator.saveAndShow(Self.makeTranscript(text: "a dictation"))
    try coordinator.saveAndShow(
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
  func searchReachesTheImportedFileName() throws {
    let dir = Self.makeTempDir()
    defer { Self.cleanup(dir) }
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
    let imported = Transcript(
      text: "um so the numbers for the quarter", language: "en", duration: 61,
      backendType: .parakeet, importedFileName: "marketing_sync.wav")
    let dictated = Self.makeTranscript(text: "a plain dictation")
    try coordinator.saveAndShow(imported)
    try coordinator.saveAndShow(dictated)

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

    try coordinator.saveAndShow(row)
    #expect(coordinator.hasRow(id: row.id))
    #expect(try coordinator.updateExistingRow(cleaned) == true)
    #expect(coordinator.visibleTranscripts.count == 1)
    #expect(coordinator.visibleTranscripts.first?.displayText == "One two three.")
    #expect(FileManager.default.fileExists(atPath: onDisk))

    coordinator.delete(row)
    #expect(coordinator.visibleTranscripts.isEmpty)
    #expect(!coordinator.hasRow(id: row.id))
    #expect(!FileManager.default.fileExists(atPath: onDisk))

    #expect(try coordinator.updateExistingRow(cleaned) == false)
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

    // A read-only folder: the file cannot be removed.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    coordinator.delete(row)
    #expect(coordinator.actionFailure == .delete)
    #expect(coordinator.visibleTranscripts.map(\.id) == [row.id])

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
      coordinator.deleteAll()
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
    coordinator.keep(held)
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
    coordinator.delete(row)
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
    try coordinator.saveAndShow(raw)
    let pressed = raw  // the copy History Paste captured

    // An import's cleanup lands while History is hidden.
    let cleaned = Transcript(
      id: raw.id, text: "Cleaned words.", processingTime: 0.1, backendType: .parakeet,
      createdAt: raw.createdAt)
    #expect(try coordinator.updateExistingRow(cleaned))
    #expect(coordinator.textForDelivery(pressed) == "Cleaned words.")

    // Deleted in that wait: nothing is delivered.
    coordinator.delete(raw)
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

    coordinator.delete(row)
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
    let url = FileManager.default.temporaryDirectory
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
    try coordinator.saveAndShow(dictation)
    var announced: [UUID] = []
    coordinator.onRowDeleted = { announced.append($0) }
    var handed: [UUID] = []
    coordinator.deleteMeeting = { handed.append($0) }

    coordinator.delete(meetingRow)
    #expect(handed == [meetingID])
    #expect(coordinator.hasRow(id: meetingRow.id), "EnviousMeet removes it, in its own order")

    try coordinator.removeRow(id: meetingRow.id)
    #expect(coordinator.hasRow(id: meetingRow.id) == false)
    #expect(FileManager.default.fileExists(
      atPath: dir.appendingPathComponent("\(meetingRow.id.uuidString).json").path) == false)
    // A row already gone (Delete All ran first) is not an error.
    try coordinator.removeRow(id: meetingRow.id)
    #expect(announced.isEmpty)

    // Ordinary rows keep the ordinary delete.
    coordinator.delete(dictation)
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
    try coordinator.saveAndShow(Transcript(text: "a dictation", backendType: .parakeet))
    let rowURL = dir.appendingPathComponent("\(row.id.uuidString).json")
    var rowExistedWhenMarked: Bool?
    var allowed = false
    coordinator.meetingsWillBeDeletedWithAll = { ids in
      #expect(ids == [meetingID])
      rowExistedWhenMarked = FileManager.default.fileExists(atPath: rowURL.path)
      return allowed
    }
    // A meeting that could not be marked: nothing is deleted.
    coordinator.deleteAll()
    #expect(coordinator.actionFailure == .deleteAll)
    #expect(rowExistedWhenMarked == true)
    #expect(coordinator.listedCount == 2)
    #expect(FileManager.default.fileExists(atPath: rowURL.path))

    coordinator.dismissActionFailure()
    allowed = true
    coordinator.deleteAll()
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
      let failure = coordinator.renameSpeaker(
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
      #expect(
        coordinator.renameSpeaker(id: id, speakerId: "mic:1", name: "Ana", isMeeting: true) == nil)
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
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0.hasSuffix(".tmp") }.isEmpty)
  }
}
