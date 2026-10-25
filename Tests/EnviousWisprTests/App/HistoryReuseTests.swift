import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage
import EnviousWisprAppKitTestSupport

/// History reopen reuse (#4001 H9). Driven against REAL stores in temp directories: a second
/// `TranscriptStore` on the same folder stands in for another app copy, so every "changed" case
/// is a real write through the shipping writer, never a simulated token.
@MainActor
@Suite("History reuses its rows while the store is unchanged (#4001 H9)", .tags(.productOutcome))
struct HistoryReuseTests {

  private static func makeTempDir() -> URL {
    TestTemporaryDirectory.url
      .appendingPathComponent("4001-reuse-\(UUID().uuidString)", isDirectory: true)
  }

  private static func row(_ text: String = "hello", id: UUID = UUID(), age: TimeInterval = 0)
    -> Transcript
  {
    Transcript(
      id: id, text: text, processingTime: 0.1, backendType: .parakeet,
      createdAt: Date().addingTimeInterval(-age))
  }

  private static func heldRow() -> Transcript {
    let now = Date()
    return Transcript(
      text: "held", createdAt: now, escapeRecoveredAt: now, escapeRecoveryTakeID: "TAKE-1")
  }

  // #4075 G8: History cancels a read a newer one replaces. The cancellation reaches the disk
  // walk, which stops instead of decoding every row file.
  @Test("a cancelled History read stops instead of reading every row file")
  func cancelledReadStops() async throws {
    let dir = Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptStore(directory: dir)
    for index in 0..<500 { try store.save(Self.row("row \(index)")) }
    let read = Task { try await store.readHistory() }
    read.cancel()
    await #expect(throws: CancellationError.self) { try await read.value }
    // Control: the same store reads in full when nothing cancels it.
    #expect(try await store.readHistory().permanent.count == 500)
  }

  #if DEBUG
    /// Counts row files a read reached; the worker thread and the test both touch it.
    private final class ReadCount: @unchecked Sendable {
      private let lock = NSLock()
      private var count = 0
      func next() -> Int { lock.withLock { count += 1; return count } }
      var value: Int { lock.withLock { count } }
    }

    @Test("a History read cancelled mid-walk stops before reading the remaining row files")
    func cancelledMidWalkStops() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let store = TranscriptStore(directory: dir)
      for index in 0..<500 { try store.save(Self.row("row \(index)")) }
      let reached = ReadCount()
      let started = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      store.permanentFileWillReadForTesting = {
        guard reached.next() == 1 else { return }
        started.signal()
        // deadline-fallback: the test signals the release; 10 s only frees a test that never does.
        _ = release.wait(timeout: .now() + 10)
      }
      let read = Task { try await store.readHistory() }
      // Waited on a dispatch thread, off the main actor the read's caller needs.
      await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
          // deadline-fallback: the walk signals at its first file; 10 s only frees a broken read.
          _ = started.wait(timeout: .now() + 10)
          continuation.resume()
        }
      }
      read.cancel()
      release.signal()
      await #expect(throws: CancellationError.self) { try await read.value }
      #expect(reached.value == 1, "the walk stopped at the next file, not after all 500")
    }
  #endif

  private static func isEmpty(_ detail: HistoryDetail) -> Bool {
    if case .empty = detail { return true }
    return false
  }

  // The coordinator's read and reuse counters exist only in Debug builds.
  #if DEBUG
    private func open(_ coordinator: TranscriptCoordinator) async {
      coordinator.loadIfNeeded()
      await coordinator.waitForLoadForTesting()
    }

    private func texts(_ coordinator: TranscriptCoordinator) -> [String] {
      coordinator.filteredTranscripts.map(\.text)
    }

    // MARK: - Reuse

    @Test("reopening an unchanged store reads it once, with no pending folder ever created")
    func unchangedStoreIsReadOnce() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let other = TranscriptStore(directory: dir)
      try other.save(Self.row("one", age: 10))
      try other.save(Self.row("two"))
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))

      for _ in 0..<5 { await open(coordinator) }

      #expect(coordinator.historyFullReadsForTesting == 1)
      #expect(coordinator.historyCacheHitsForTesting == 4)
      #expect(texts(coordinator) == ["two", "one"])
      #expect(
        !FileManager.default.fileExists(
          atPath: dir.appendingPathComponent(AppConstants.pendingTranscriptsDir).path))
    }

    @Test("an empty store is a complete read and is reused")
    func emptyStoreIsReused() async {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      await open(coordinator)
      await open(coordinator)
      #expect(coordinator.historyFullReadsForTesting == 1)
      #expect(coordinator.historyCacheHitsForTesting == 1)
    }

    @Test("two opens before the first finishes share one read")
    func concurrentOpensJoin() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      try TranscriptStore(directory: dir).save(Self.row())
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      coordinator.loadIfNeeded()
      coordinator.loadIfNeeded()
      await coordinator.waitForLoadForTesting()
      #expect(coordinator.historyFullReadsForTesting == 1)
      #expect(coordinator.historyCacheHitsForTesting == 0)
    }

    @Test("an explicit load always reads the store")
    func explicitLoadAlwaysReads() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      await open(coordinator)
      coordinator.load()
      await coordinator.waitForLoadForTesting()
      #expect(coordinator.historyFullReadsForTesting == 2)
    }

    // MARK: - Changes force a read

    @Test("a row added by another store appears on the next open")
    func externalAdditionIsDiscovered() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let other = TranscriptStore(directory: dir)
      try other.save(Self.row("first", age: 10))
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      await open(coordinator)

      try other.save(Self.row("second"))
      await open(coordinator)

      #expect(coordinator.historyFullReadsForTesting == 2)
      #expect(texts(coordinator) == ["second", "first"])
      await open(coordinator)
      #expect(coordinator.historyCacheHitsForTesting == 1, "and the new read is reused in turn")
    }

    @Test("rapid replacements of one row by another store are all detected")
    func externalReplacementIsDiscovered() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let other = TranscriptStore(directory: dir)
      let id = UUID()
      try other.save(Self.row("v0", id: id))
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      await open(coordinator)

      for version in 1...3 {
        try other.save(Self.row("v\(version)", id: id))
        await open(coordinator)
        #expect(texts(coordinator) == ["v\(version)"])
      }
      #expect(coordinator.historyFullReadsForTesting == 4)
      #expect(coordinator.historyCacheHitsForTesting == 0)
    }

    @Test("this app's own write makes the next open read the store")
    func localWriteForcesRead() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      await open(coordinator)
      try coordinator.saveAndShow(Self.row("local"))
      #expect(texts(coordinator) == ["local"], "visible at once, without an open")
      await open(coordinator)
      #expect(coordinator.historyFullReadsForTesting == 2)
      #expect(texts(coordinator) == ["local"])
    }

    @Test("a write before History ever opened is visible, and the first open still reads")
    func writeBeforeFirstOpen() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      try coordinator.saveAndShow(Self.row("early"))
      #expect(texts(coordinator) == ["early"])
      await open(coordinator)
      #expect(coordinator.historyFullReadsForTesting == 1)
      #expect(texts(coordinator) == ["early"])
    }

    @Test("a held row created by another store, the first in pending, forces a read")
    func firstPendingRowForcesRead() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      await open(coordinator)
      try TranscriptStore(directory: dir).savePending(Self.heldRow())
      await open(coordinator)
      #expect(coordinator.historyFullReadsForTesting == 2)
    }

    @Test("Delete All, which also removes the pending folder, forces a read")
    func deleteAllForcesRead() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let other = TranscriptStore(directory: dir)
      try other.save(Self.row())
      try other.savePending(Self.heldRow())
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      await open(coordinator)
      let shown = try #require(coordinator.filteredTranscripts.first { $0.text == "hello" })
      coordinator.selectedItemID = .transcript(shown.id)
      try other.deleteAll()
      await open(coordinator)
      #expect(coordinator.historyFullReadsForTesting == 2)
      #expect(texts(coordinator).isEmpty)
      #expect(coordinator.lastPasteableDictation() == nil)
      // #4075 R8: the selection and the pane let go of the deleted row, and Paste refuses it.
      #expect(coordinator.selectedItemID == nil)
      #expect(Self.isEmpty(coordinator.detail))
      #expect(coordinator.textForDelivery(shown) == nil)
      // And it stays gone across another open, which reuses the read.
      await open(coordinator)
      #expect(texts(coordinator).isEmpty)
      #expect(coordinator.lastPasteableDictation() == nil)
      #expect(coordinator.selectedItemID == nil)
      #expect(Self.isEmpty(coordinator.detail))
      #expect(coordinator.textForDelivery(shown) == nil)
    }

    @Test("a row another store deletes leaves History and Paste Last on the next open")
    func externalDeleteLeavesHistoryAndPasteLast() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let other = TranscriptStore(directory: dir)
      let kept = Self.row("kept", age: 10)
      let deleted = Self.row("deleted")
      try other.save(kept)
      try other.save(deleted)
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))
      await open(coordinator)
      #expect(coordinator.lastPasteableDictation()?.id == deleted.id)
      coordinator.selectedItemID = .transcript(deleted.id)

      try other.delete(id: deleted.id)
      await open(coordinator)

      #expect(texts(coordinator) == ["kept"])
      #expect(coordinator.lastPasteableDictation()?.id == kept.id)
      #expect(coordinator.lastDictationTextForReuse(id: deleted.id) == nil)
      // #4075 R8, R5: the selection moves off the deleted row, and History Paste refuses it.
      #expect(coordinator.selectedItemID == nil)
      #expect(Self.isEmpty(coordinator.detail))
      #expect(coordinator.textForDelivery(deleted) == nil)
      await open(coordinator)
      #expect(coordinator.selectedItemID == nil)
      #expect(Self.isEmpty(coordinator.detail))
      #expect(coordinator.textForDelivery(deleted) == nil)
    }

    @Test("a dictation appended after its file was saved survives the next open")
    func appendedDictationSurvivesOpen() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let store = TranscriptStore(directory: dir)
      let coordinator = TranscriptCoordinator(store: store)
      await open(coordinator)
      // The heart path's order: save the file, then append the row.
      let fresh = Self.row("fresh")
      try store.save(fresh)
      coordinator.append(fresh)
      await open(coordinator)
      #expect(texts(coordinator) == ["fresh"])
      #expect(coordinator.lastPasteableDictation()?.id == fresh.id)
    }

    @Test("a row file that cannot be read keeps the next open reading until it can")
    func unreadableRowIsRetried() async throws {
      let dir = Self.makeTempDir()
      defer { try? FileManager.default.removeItem(at: dir) }
      let other = TranscriptStore(directory: dir)
      let blocked = Self.row("blocked")
      // A folder where the row file belongs: listed like a row, and fails to read. A permission
      // change would not hold, because a store's start-up migration resets row files to 0600.
      let file = dir.appendingPathComponent("\(blocked.id.uuidString).json")
      try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
      let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: dir))

      await open(coordinator)
      await open(coordinator)
      #expect(coordinator.historyFullReadsForTesting == 2, "an incomplete read is never reused")
      #expect(texts(coordinator).isEmpty)

      try FileManager.default.removeItem(at: file)
      try other.save(blocked)
      await open(coordinator)
      #expect(texts(coordinator) == ["blocked"])
      await open(coordinator)
      #expect(coordinator.historyCacheHitsForTesting == 1)
    }
  #endif

  // MARK: - Store tokens

  @Test("every entry-changing store write changes the folder tokens; no write leaves them equal")
  func everyWriterChangesTokens() async throws {
    let dir = Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptStore(directory: dir)
    var last = try #require(await store.freshness())
    #expect(last.pending == .absent)
    #expect(await store.freshness() == last, "an unchanged folder reads the same twice")

    let kept = Self.heldRow()
    let permanent = Self.row("p")
    let steps: [(String, () async throws -> Void)] = [
      ("save", { try store.save(permanent) }),
      ("replace", { try store.save(Self.row("p2", id: permanent.id)) }),
      ("durable", { try store.durableWriter()(Self.row("d")) }),
      ("pending save", { try store.savePending(kept) }),
      ("promote", { _ = try store.promotePending(id: kept.id) }),
      ("delete", { try store.delete(id: permanent.id) }),
      ("delete all", { try store.deleteAll() }),
    ]
    for (name, step) in steps {
      try await step()
      let now = try #require(await store.freshness(), "\(name): token unknown")
      #expect(now != last, "\(name) left the tokens unchanged")
      last = now
    }
  }

  @Test("an unreadable pending folder certifies nothing")
  func unreadablePendingFolderIsNotCertified() async throws {
    let dir = Self.makeTempDir()
    let pending = dir.appendingPathComponent(AppConstants.pendingTranscriptsDir)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pending.path)
      try? FileManager.default.removeItem(at: dir)
    }
    let store = TranscriptStore(directory: dir)
    try store.savePending(Self.heldRow())
    #expect(try await store.readHistory().freshness != nil, "readable: certified")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: pending.path)
    #expect(try await store.readHistory().freshness == nil)
  }

  @Test(
    "a held row file that cannot be read certifies nothing; one that reads but is malformed does")
  func unreadablePendingFileIsNotCertified() async throws {
    let dir = Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptStore(directory: dir)
    try store.savePending(Self.heldRow())
    let pending = dir.appendingPathComponent(AppConstants.pendingTranscriptsDir)
    try Data("not json".utf8).write(to: pending.appendingPathComponent("\(UUID().uuidString).json"))
    #expect(try await store.readHistory().freshness != nil, "malformed: excluded, still certified")
    // A folder where a row file belongs is listed like a row and fails to read.
    try FileManager.default.createDirectory(
      at: pending.appendingPathComponent("\(UUID().uuidString).json"),
      withIntermediateDirectories: false)
    #expect(try await store.readHistory().freshness == nil)
  }
}
