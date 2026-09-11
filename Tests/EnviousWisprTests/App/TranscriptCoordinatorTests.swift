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

  @Test("load during a concurrent append merges both rows")
  func testLoadDuringAppendMergesCorrectly() async throws {
    let dir = Self.makeTempDir()
    defer { Self.cleanup(dir) }
    let diskOnly = Self.makeTranscript(text: "disk")
    try Self.writeToDisk([diskOnly], in: dir)
    let store = TranscriptStore(directory: dir)
    let coordinator = TranscriptCoordinator(store: store)

    // Simulate the race: an append arrives before load() finishes.
    let newRow = Self.makeTranscript(text: "appended")
    coordinator.append(newRow)
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

    // Three rapid appends, all before load finishes.
    let r1 = Self.makeTranscript(text: "r1")
    let r2 = Self.makeTranscript(text: "r2")
    let r3 = Self.makeTranscript(text: "r3")
    coordinator.append(r1)
    coordinator.append(r2)
    coordinator.append(r3)
    coordinator.load()
    await coordinator.waitForLoadForTesting()

    // Pre-merge in-memory order was [r3, r2, r1] (each append inserts at 0).
    // After merge: in-memory rows first (order preserved), then disk row.
    let ids = coordinator.visibleTranscripts.map(\.id)
    #expect(ids == [r3.id, r2.id, r1.id, diskRow.id])
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
