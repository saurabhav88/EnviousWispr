import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing
import EnviousWisprAppKitTestSupport

/// #636 — `addBatch` / `removeBatch`: single-save bulk ops mirroring the
/// per-word `add(word:)` / `remove(id:)` semantics.
@MainActor
@Suite("CustomWordsManager — addBatch / removeBatch (#636)")
struct CustomWordsBatchTests {
  private static func tempManager() -> (CustomWordsManager, URL) {
    let dir = TestTemporaryDirectory.url
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
  func allNew() async throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let a = person("Ramachandran Test")
    let b = person("Vasquez Test")
    let ids = try await mgr.addBatch([a, b], to: &words)
    #expect(ids == [a.id, b.id])
    #expect(words.contains { $0.canonical == "Ramachandran Test" })
    #expect(words.contains { $0.canonical == "Vasquez Test" })
  }

  @Test("Case-insensitive duplicates are skipped; only new IDs returned")
  func skipsDuplicates() async throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let first = person("Okafor Test")
    _ = try await mgr.addBatch([first], to: &words)

    let dup = person("okafor test")  // case-insensitive duplicate of existing
    let fresh = person("Nakamura Test")
    let ids = try await mgr.addBatch([dup, fresh], to: &words)
    #expect(ids == [fresh.id])
    #expect(words.filter { $0.canonical.lowercased() == "okafor test" }.count == 1)
  }

  @Test("Duplicates within the same batch collapse to one")
  func intraBatchDedupe() async throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let one = person("Same Person")
    let two = person("same person")
    let ids = try await mgr.addBatch([one, two], to: &words)
    #expect(ids == [one.id])
  }

  @Test("Empty / blank-canonical input is a no-op")
  func emptyAndBlank() async throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let before = words.count
    #expect(try await mgr.addBatch([], to: &words).isEmpty)
    #expect(try await mgr.addBatch([person("   ")], to: &words).isEmpty)
    #expect(words.count == before)
  }

  @Test("Batch additions persist across a reload")
  func persistsAcrossReload() async throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    _ = try await mgr.addBatch([person("Persisted Person")], to: &words)
    let reloaded = CustomWordsManager(fileURL: url).load() ?? []
    #expect(reloaded.contains { $0.canonical == "Persisted Person" })
  }

  @Test("removeBatch removes exactly the given IDs and leaves the rest")
  func removeBatchExact() async throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let a = person("Remove One")
    let b = person("Keep Two")
    _ = try await mgr.addBatch([a, b], to: &words)
    try await mgr.removeBatch(ids: [a.id], from: &words)
    #expect(!words.contains { $0.id == a.id })
    #expect(words.contains { $0.id == b.id })
  }

  @Test("removeBatch with empty IDs is a no-op")
  func removeBatchEmpty() async throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let before = words.count
    try await mgr.removeBatch(ids: [], from: &words)
    #expect(words.count == before)
  }

  // #636 follow-up, narrowed in #4086 — applyGeneratedAliases: the contacts-import
  // enrichment flush fills empty alias lists in one save, and only on a word that is
  // still the one the aliases were generated for.

  @Test("generated aliases land on the word they were made for and persist across reload")
  func generatedAliasesPersist() async throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let a = person("Ramachandran Test")
    let b = person("Vasquez Test")
    _ = try await mgr.addBatch([a, b], to: &words)

    try await mgr.applyGeneratedAliases(
      [GeneratedAliasProposal(id: a.id, canonical: a.canonical, aliases: ["rama", "ram uh"])],
      to: &words)

    #expect(words.first { $0.canonical == "Ramachandran Test" }?.aliases == ["rama", "ram uh"])
    let reloaded = CustomWordsManager(fileURL: url).load() ?? []
    #expect(reloaded.first { $0.canonical == "Ramachandran Test" }?.aliases == ["rama", "ram uh"])
    // The untouched word keeps its empty alias list.
    #expect(reloaded.first { $0.canonical == "Vasquez Test" }?.aliases.isEmpty == true)
  }

  @Test("a generated alias for a missing id is skipped — never resurrects a removed word")
  func generatedAliasesMissingIdNoOp() async throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    _ = try await mgr.addBatch([person("Ramachandran Test")], to: &words)

    let ghost = person("Ghost Test")  // never added to the file
    let receipt = try await mgr.applyGeneratedAliases(
      [GeneratedAliasProposal(id: ghost.id, canonical: ghost.canonical, aliases: ["boo"])])

    #expect(receipt.value == nil && receipt.committed == false)
    let reloaded = CustomWordsManager(fileURL: url).load() ?? []
    #expect(!reloaded.contains { $0.canonical == "Ghost Test" })
  }

  @Test("no generated aliases is a no-op that writes nothing")
  func generatedAliasesEmpty() async throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    let receipt = try await mgr.applyGeneratedAliases([])
    #expect(receipt.value == nil && receipt.committed == false)
  }

  @Test(
    "a word renamed, given aliases or moved out of Person since the aliases were generated is left exactly as it is"
  )
  func staleGeneratedAliasesAreSkipped() async throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let renamed = person("Renamed Test")
    let aliased = person("Aliased Test")
    let moved = person("Moved Test")
    let fresh = person("Fresh Test")
    _ = try await mgr.addBatch([renamed, aliased, moved, fresh], to: &words)
    // The user edits three of them while the aliases are being generated.
    var edit = try #require(words.first { $0.id == renamed.id })
    edit.canonical = "Renamed By User"
    edit.priority = 7
    try await mgr.update(word: edit, in: &words)
    edit = try #require(words.first { $0.id == aliased.id })
    edit.aliases = ["typed by user"]
    try await mgr.update(word: edit, in: &words)
    edit = try #require(words.first { $0.id == moved.id })
    edit.category = .brand
    try await mgr.update(word: edit, in: &words)
    let before = words

    try await mgr.applyGeneratedAliases(
      [renamed, aliased, moved, fresh].map {
        GeneratedAliasProposal(id: $0.id, canonical: $0.canonical, aliases: ["gen"])
      }, to: &words)

    for id in [renamed.id, aliased.id, moved.id] {
      #expect(words.first { $0.id == id } == before.first { $0.id == id }, "a user edit was overwritten")
    }
    #expect(words.first { $0.id == fresh.id }?.aliases == ["gen"])
    #expect(try #require(mgr.load()) == words, "disk agrees")
  }

  // MARK: - Learned provenance through the batch doors (#996)

  @Test("addBatch prunes a mark outside aliases, keeps a trimmed alias's mark, and leaves every other field alone")
  func batchDoorsNormalizeLearnedMarks() async throws {
    let (mgr, url) = Self.tempManager()
    defer { Self.cleanup(url) }
    var words = mgr.load() ?? []
    let learnedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let a = CustomWord(
      canonical: "Tuist Test", aliases: [" twist "], category: .brand, priority: 2,
      learnedAliases: [" twist ", "ghost"], learnedAt: learnedAt)
    let ids = try await mgr.addBatch([a], to: &words)
    #expect(ids == [a.id])
    let added = try #require(words.first { $0.id == a.id })
    #expect(added.aliases == ["twist"] && added.learnedAliases == ["twist"])
    #expect(added.learnedAt == learnedAt && added.category == .brand && added.priority == 2)
  }
}
