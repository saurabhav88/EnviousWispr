import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #636 — `addBatch` / `removeBatch`: single-save bulk ops mirroring the
/// per-word `add(word:)` / `remove(id:)` semantics.
@MainActor
@Suite("CustomWordsManager — addBatch / removeBatch (#636)")
struct CustomWordsBatchTests {
  private static func tempManager() -> (CustomWordsManager, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EnviousWispr-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("custom-words.json")
    return (CustomWordsManager(fileURL: url), url)
  }

  private static func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  private func person(_ canonical: String) -> CustomWord {
    CustomWord(canonical: canonical, category: .person, priority: 10)
  }

  @Test("All-new batch creates every word and returns their IDs in input order")
  func allNew() throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let a = person("Ramachandran Test")
    let b = person("Vasquez Test")
    let ids = try mgr.addBatch([a, b], to: &words)
    #expect(ids == [a.id, b.id])
    #expect(words.contains { $0.canonical == "Ramachandran Test" })
    #expect(words.contains { $0.canonical == "Vasquez Test" })
  }

  @Test("Case-insensitive duplicates are skipped; only new IDs returned")
  func skipsDuplicates() throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let first = person("Okafor Test")
    _ = try mgr.addBatch([first], to: &words)

    let dup = person("okafor test")  // case-insensitive duplicate of existing
    let fresh = person("Nakamura Test")
    let ids = try mgr.addBatch([dup, fresh], to: &words)
    #expect(ids == [fresh.id])
    #expect(words.filter { $0.canonical.lowercased() == "okafor test" }.count == 1)
  }

  @Test("Duplicates within the same batch collapse to one")
  func intraBatchDedupe() throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let one = person("Same Person")
    let two = person("same person")
    let ids = try mgr.addBatch([one, two], to: &words)
    #expect(ids == [one.id])
  }

  @Test("Empty / blank-canonical input is a no-op")
  func emptyAndBlank() throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let before = words.count
    #expect(try mgr.addBatch([], to: &words).isEmpty)
    #expect(try mgr.addBatch([person("   ")], to: &words).isEmpty)
    #expect(words.count == before)
  }

  @Test("Batch additions persist across a reload")
  func persistsAcrossReload() throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    _ = try mgr.addBatch([person("Persisted Person")], to: &words)
    let reloaded = CustomWordsManager(fileURL: url).load() ?? []
    #expect(reloaded.contains { $0.canonical == "Persisted Person" })
  }

  @Test("removeBatch removes exactly the given IDs and leaves the rest")
  func removeBatchExact() throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let a = person("Remove One")
    let b = person("Keep Two")
    _ = try mgr.addBatch([a, b], to: &words)
    try mgr.removeBatch(ids: [a.id], from: &words)
    #expect(!words.contains { $0.id == a.id })
    #expect(words.contains { $0.id == b.id })
  }

  @Test("removeBatch with empty IDs is a no-op")
  func removeBatchEmpty() throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let before = words.count
    try mgr.removeBatch(ids: [], from: &words)
    #expect(words.count == before)
  }

  // #636 follow-up — updateBatch: single-save bulk alias update used by the
  // contacts-import enrichment flush.

  @Test("updateBatch updates aliases for existing words and persists across reload")
  func updateBatchPersists() throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let a = person("Ramachandran Test")
    let b = person("Vasquez Test")
    _ = try mgr.addBatch([a, b], to: &words)

    var aUpd = try #require(words.first { $0.canonical == "Ramachandran Test" })
    aUpd.aliases = ["rama", "ram uh"]
    try mgr.updateBatch([aUpd], to: &words)

    #expect(words.first { $0.canonical == "Ramachandran Test" }?.aliases == ["rama", "ram uh"])
    let reloaded = CustomWordsManager(fileURL: url).load() ?? []
    #expect(reloaded.first { $0.canonical == "Ramachandran Test" }?.aliases == ["rama", "ram uh"])
    // The untouched word keeps its empty alias list.
    #expect(reloaded.first { $0.canonical == "Vasquez Test" }?.aliases.isEmpty == true)
  }

  @Test("updateBatch skips a missing id — never resurrects a removed word")
  func updateBatchMissingIdNoOp() throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    _ = try mgr.addBatch([person("Ramachandran Test")], to: &words)

    var ghost = person("Ghost Test")  // never added to the file
    ghost.aliases = ["boo"]
    try mgr.updateBatch([ghost], to: &words)

    #expect(!words.contains { $0.canonical == "Ghost Test" })
    let reloaded = CustomWordsManager(fileURL: url).load() ?? []
    #expect(!reloaded.contains { $0.canonical == "Ghost Test" })
  }

  @Test("updateBatch with empty input is a no-op")
  func updateBatchEmpty() throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let before = words.count
    try mgr.updateBatch([], to: &words)
    #expect(words.count == before)
  }
}
