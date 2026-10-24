import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// History reopen reuse (#4001 H9). Driven against REAL stores in temp directories: a second
/// `TranscriptStore` on the same folder stands in for another app copy, so every "changed" case
/// is a real write through the shipping writer, never a simulated token.
@MainActor
@Suite("History reuses its rows while the store is unchanged (#4001 H9)", .tags(.productOutcome))
struct HistoryReuseTests {

  private static func makeTempDir() -> URL {
    FileManager.default.temporaryDirectory
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
      try other.deleteAll()
      await open(coordinator)
      #expect(coordinator.historyFullReadsForTesting == 2)
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
}
