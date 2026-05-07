import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Phase 3b (#631) audit follow-up #648 — pins the disk round-trip behavior
/// of the debounced counting writer. Confirms `recordReplacements` actually
/// updates `frequencyUsed` and `lastUsed` on entries persisted to disk.
///
/// Uses the package-internal `init(fileURL:)` test seam to avoid the
/// production Application Support path.
@MainActor
@Suite("CustomWordsManager — counting writer disk round-trip (#648)")
struct CustomWordsManagerDiskRoundTripTests {

  private static func tempFileURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EnviousWispr-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("custom-words.json")
  }

  private static func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  /// Write a fresh `custom-words.json` with the given user words at the given
  /// path so the test starts from a known state.
  private static func seed(path: URL, words: [CustomWord]) throws {
    struct File: Codable {
      var version: Int = 1
      var builtinsVersion: Int = 1
      var deletedBuiltinIds: [String] = []
      var words: [CustomWord] = []
    }
    var file = File()
    file.words = words
    let data = try JSONEncoder().encode(file)
    try data.write(to: path, options: [.atomic])
  }

  /// Decode the persisted file as an opaque dict to read frequencyUsed +
  /// lastUsed without depending on the manager's private CustomWordsFile shape.
  private static func readWords(at path: URL) throws -> [CustomWord] {
    let data = try Data(contentsOf: path)
    struct File: Codable {
      let words: [CustomWord]
    }
    return try JSONDecoder().decode(File.self, from: data).words
  }

  @Test("recordReplacements + flush updates frequencyUsed on disk")
  func frequencyUsedPersisted() throws {
    let path = Self.tempFileURL()
    defer { Self.cleanup(path) }

    let word1 = CustomWord(canonical: "Kubernetes")
    let word2 = CustomWord(canonical: "Snowflake")
    let word3 = CustomWord(canonical: "Databricks")
    try Self.seed(path: path, words: [word1, word2, word3])

    let manager = CustomWordsManager(fileURL: path)
    // word1 hit once, word2 hit twice, word3 not hit.
    manager.recordReplacements([word1.id, word2.id, word2.id])
    manager.flushPendingIncrementsForTesting()

    let after = try Self.readWords(at: path)
    let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
    #expect(byID[word1.id]?.frequencyUsed == 1, "word1 hit once")
    #expect(byID[word2.id]?.frequencyUsed == 2, "word2 hit twice")
    #expect(byID[word3.id]?.frequencyUsed == 0, "word3 not hit")
  }

  @Test("recordReplacements + flush updates lastUsed on disk")
  func lastUsedPersisted() throws {
    let path = Self.tempFileURL()
    defer { Self.cleanup(path) }

    let word = CustomWord(canonical: "Kubernetes")
    try Self.seed(path: path, words: [word])
    let beforeFlush = Date()

    let manager = CustomWordsManager(fileURL: path)
    manager.recordReplacements([word.id])
    manager.flushPendingIncrementsForTesting()

    let after = try Self.readWords(at: path)
    let lastUsed = after.first(where: { $0.id == word.id })?.lastUsed
    #expect(lastUsed != nil, "lastUsed must be populated")
    if let ts = lastUsed {
      // Allow generous tolerance — the writer captures `Date()` inside
      // recordReplacements which fires before flush.
      #expect(ts >= beforeFlush.addingTimeInterval(-1))
      #expect(ts <= Date().addingTimeInterval(1))
    }
  }

  @Test("Unknown UUIDs are skipped silently — no file mutation")
  func unknownIDsSkipped() throws {
    let path = Self.tempFileURL()
    defer { Self.cleanup(path) }

    let word = CustomWord(canonical: "Kubernetes")
    try Self.seed(path: path, words: [word])

    let manager = CustomWordsManager(fileURL: path)
    let randomID = UUID()
    manager.recordReplacements([randomID])
    manager.flushPendingIncrementsForTesting()

    let after = try Self.readWords(at: path)
    #expect(after.first?.frequencyUsed == 0, "Unknown ID does not bump existing entries")
  }

  @Test("Mixed known + unknown IDs: known increments, unknown silently dropped")
  func mixedKnownUnknown() throws {
    let path = Self.tempFileURL()
    defer { Self.cleanup(path) }

    let word = CustomWord(canonical: "Kubernetes")
    try Self.seed(path: path, words: [word])

    let manager = CustomWordsManager(fileURL: path)
    manager.recordReplacements([word.id, UUID(), UUID()])
    manager.flushPendingIncrementsForTesting()

    let after = try Self.readWords(at: path)
    #expect(after.first?.frequencyUsed == 1)
  }

  @Test("add persists aliases and matching policy in one write")
  func addPersistsFullCustomWord() throws {
    let path = Self.tempFileURL()
    defer { Self.cleanup(path) }

    let manager = CustomWordsManager(fileURL: path)
    var words: [CustomWord] = []
    let word = CustomWord(
      canonical: "  GitLab  ",
      aliases: [" git lab ", ""],
      category: .brand,
      forceReplace: true,
      minSimilarityOverride: 0.92
    )

    try manager.add(word: word, to: &words)

    let after = try Self.readWords(at: path)
    #expect(after.count == 1)
    #expect(after.first?.canonical == "GitLab")
    #expect(after.first?.aliases == ["git lab"])
    #expect(after.first?.category == .brand)
    #expect(after.first?.forceReplace == true)
    #expect(after.first?.minSimilarityOverride == 0.92)
    let runtimeAdded = words.first { $0.canonical == "GitLab" }
    #expect(runtimeAdded?.aliases == ["git lab"])
  }

  @Test("Multiple flushes accumulate frequencyUsed across writes")
  func multipleFlushesAccumulate() throws {
    let path = Self.tempFileURL()
    defer { Self.cleanup(path) }

    let word = CustomWord(canonical: "Kubernetes")
    try Self.seed(path: path, words: [word])

    let manager = CustomWordsManager(fileURL: path)
    manager.recordReplacements([word.id])
    manager.flushPendingIncrementsForTesting()
    manager.recordReplacements([word.id, word.id])
    manager.flushPendingIncrementsForTesting()
    manager.recordReplacements([word.id])
    manager.flushPendingIncrementsForTesting()

    let after = try Self.readWords(at: path)
    #expect(after.first?.frequencyUsed == 4, "1 + 2 + 1 = 4 across three flushes")
  }
}
