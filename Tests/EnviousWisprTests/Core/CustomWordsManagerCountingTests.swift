import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Phase 3b (#631) — pins the debounced counting writer's distinct behaviors:
/// below-threshold records stay pending (not persisted) until flush, the
/// 50-count threshold triggers an immediate auto-flush, repeated/mixed
/// increments accumulate, and an empty flush is a true no-op.
///
/// Rewritten for #881: the prior version of this suite asserted `#expect(true)`
/// on every case (it claimed the manager exposed no test seam — false; the
/// `init(fileURL:)` package seam used by `CustomWordsManagerDiskRoundTripTests`
/// exists). Each test now drives that seam and asserts the persisted
/// `frequencyUsed` so a real regression in the counting writer fails the suite.
/// Disk round-trip basics (single/double hit, unknown id) are covered by
/// `CustomWordsManagerDiskRoundTripTests`; this suite owns the threshold,
/// accumulation, and pending-vs-flush semantics.
/// Bible §9.3.
@MainActor
@Suite("CustomWordsManager — Phase 3b debounced counting writer")
struct CustomWordsManagerCountingTests {

  private static func tempFileURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EnviousWispr-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("custom-words.json")
  }

  private static func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  /// Write a fresh `custom-words.json` with the given user words at `path`.
  private static func seed(path: URL, words: [CustomWord]) throws {
    struct File: Codable {
      var version: Int = 1
      var builtinsVersion: Int = 1
      var deletedBuiltinIds: [String] = []
      var words: [CustomWord] = []
    }
    var file = File()
    file.words = words
    try JSONEncoder().encode(file).write(to: path, options: [.atomic])
  }

  private static func readWords(at path: URL) throws -> [CustomWord] {
    let data = try Data(contentsOf: path)
    struct File: Codable { let words: [CustomWord] }
    return try JSONDecoder().decode(File.self, from: data).words
  }

  private static func freq(_ words: [CustomWord], _ id: UUID) -> Int? {
    words.first { $0.id == id }?.frequencyUsed
  }

  @Test("A single below-threshold record stays pending on disk until flush")
  func singleCallStaysPendingUntilFlush() throws {
    let path = Self.tempFileURL()
    defer { Self.cleanup(path) }
    let word = CustomWord(canonical: "Kubernetes")
    try Self.seed(path: path, words: [word])

    let manager = CustomWordsManager(fileURL: path)
    manager.recordReplacements([word.id])  // 1 increment, below the 50-count threshold

    // Pending, NOT auto-flushed: disk still shows the seeded count.
    #expect(
      Self.freq(try Self.readWords(at: path), word.id) == 0,
      "below-threshold record must not persist before flush")

    manager.flushPendingIncrementsForTesting()
    #expect(
      Self.freq(try Self.readWords(at: path), word.id) == 1,
      "flush persists the pending increment")
  }

  @Test("flushPendingIncrementsForTesting with no pending increments leaves the file untouched")
  func flushEmptyIsNoOp() throws {
    let path = Self.tempFileURL()
    defer { Self.cleanup(path) }
    let word = CustomWord(canonical: "Snowflake")
    try Self.seed(path: path, words: [word])

    let manager = CustomWordsManager(fileURL: path)
    manager.flushPendingIncrementsForTesting()  // nothing recorded

    let after = try Self.readWords(at: path)
    #expect(after.count == 1, "no spurious word added")
    #expect(Self.freq(after, word.id) == 0, "no spurious increment")
  }

  @Test("The 50-count threshold auto-flushes; 49 stays pending (boundary)")
  func thresholdAutoFlushesAt50() throws {
    let path = Self.tempFileURL()
    defer { Self.cleanup(path) }
    let words = (0..<50).map { _ in CustomWord(canonical: "w-\(UUID().uuidString)") }
    try Self.seed(path: path, words: words)

    let manager = CustomWordsManager(fileURL: path)

    // 49 unique increments: below threshold → no auto-flush → disk unchanged.
    manager.recordReplacements(words.prefix(49).map(\.id))
    let at49 = try Self.readWords(at: path)
    #expect(at49.allSatisfy { $0.frequencyUsed == 0 }, "49 pending must not auto-flush")

    // The 50th unique increment crosses the threshold → immediate auto-flush,
    // with NO manual flush call.
    manager.recordReplacements([words[49].id])
    let at50 = try Self.readWords(at: path)
    #expect(
      at50.allSatisfy { $0.frequencyUsed == 1 },
      "crossing the 50-count threshold auto-flushes all pending increments")
  }

  @Test("The same id recorded ten times accumulates to frequencyUsed 10")
  func sameIDAccumulatesToTen() throws {
    let path = Self.tempFileURL()
    defer { Self.cleanup(path) }
    let word = CustomWord(canonical: "Databricks")
    try Self.seed(path: path, words: [word])

    let manager = CustomWordsManager(fileURL: path)
    for _ in 0..<10 { manager.recordReplacements([word.id]) }  // total count 10, below 50
    manager.flushPendingIncrementsForTesting()

    #expect(
      Self.freq(try Self.readWords(at: path), word.id) == 10,
      "ten separate records of one id accumulate to 10")
  }

  @Test("Mixed bulk + single records aggregate per id")
  func mixedBulkAndSingleAggregate() throws {
    let path = Self.tempFileURL()
    defer { Self.cleanup(path) }
    let words = (0..<25).map { _ in CustomWord(canonical: "w-\(UUID().uuidString)") }
    try Self.seed(path: path, words: words)

    let manager = CustomWordsManager(fileURL: path)
    manager.recordReplacements(words.map(\.id))  // all 25 once
    manager.recordReplacements(words.prefix(10).map(\.id))  // first 10 again
    manager.flushPendingIncrementsForTesting()

    let after = try Self.readWords(at: path)
    let firstTen = words.prefix(10).map(\.id)
    let lastFifteen = words.suffix(15).map(\.id)
    #expect(
      firstTen.allSatisfy { Self.freq(after, $0) == 2 }, "first 10 ids recorded twice")
    #expect(
      lastFifteen.allSatisfy { Self.freq(after, $0) == 1 }, "remaining 15 ids recorded once")
  }
}
