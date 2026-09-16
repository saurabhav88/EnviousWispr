import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #2997 — the store's one-shot import write.
///
/// `.productOutcome`: when this fails a user gets half a file imported, a duplicate trigger
/// that silently shadows another, an import that overwrites a snippet another EnviousWispr
/// process just saved, or a file rewritten for nothing.
@Suite("Snippet store import (#2997)", .tags(.productOutcome))
struct SnippetsManagerImportTests {

  private func makeManager() -> SnippetsManager {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-snippets-import-\(UUID().uuidString)", isDirectory: true)
    return SnippetsManager(fileURL: dir.appendingPathComponent("snippets.json"))
  }

  private func modificationDate(_ url: URL) throws -> Date {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.modificationDate] as? Date)
  }

  @Test("Empty additions are a no-op: no file, no write, no generation bump")
  func emptyAdditionsAreANoOp() throws {
    let fresh = makeManager()
    let untouched = try fresh.importSnippets([], reviewedAgainst: [])
    #expect(untouched.addedIDs.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fresh.storageURL.path))

    let manager = makeManager()
    let existing = Snippet(trigger: "my email", expansion: "sam@example.com")
    let saved = try manager.upsert(existing)
    let before = try modificationDate(manager.storageURL)
    let bytes = try Data(contentsOf: manager.storageURL)

    let receipt = try manager.importSnippets([], reviewedAgainst: [existing])

    #expect(receipt.addedIDs.isEmpty)
    #expect(try Data(contentsOf: manager.storageURL) == bytes)
    #expect(try modificationDate(manager.storageURL) == before)
    #expect(manager.load().generation == saved.generation)
  }

  @Test("Approved snippets land at the front, in review order, in one save")
  func additionsGoInFrontInReviewOrder() throws {
    let manager = makeManager()
    let existing = Snippet(trigger: "my email", expansion: "sam@example.com")
    let saved = try manager.upsert(existing)
    let a = Snippet(trigger: "sign off", expansion: "Best,\nSam")
    let b = Snippet(trigger: "address", expansion: "1 Main St")

    let receipt = try manager.importSnippets([a, b], reviewedAgainst: [existing])

    #expect(receipt.addedIDs == [a.id, b.id])
    #expect(receipt.vocabulary.snippets.map(\.id) == [a.id, b.id, existing.id])
    #expect(receipt.vocabulary.generation == saved.generation + 1)
    let reloaded = manager.load()
    #expect(reloaded.snippets.map(\.id) == [a.id, b.id, existing.id])
    #expect(reloaded.snippets.map(\.expansion) == ["Best,\nSam", "1 Main St", "sam@example.com"])
    #expect(reloaded.keyword == SnippetVocabulary.defaultKeyword)
  }

  @Test("The keyword is never touched by an import")
  func keywordIsUntouched() throws {
    let manager = makeManager()
    try manager.setKeyword("hey")
    _ = try manager.importSnippets(
      [Snippet(trigger: "sig", expansion: "hi")], reviewedAgainst: [])
    #expect(manager.load().keyword == "hey")
  }

  @Test("An invalid third addition writes nothing: the first two are not saved either")
  func invalidAdditionRefusesTheWholeBatch() throws {
    let manager = makeManager()
    let existing = Snippet(trigger: "my email", expansion: "sam@example.com")
    let saved = try manager.upsert(existing)
    let bytes = try Data(contentsOf: manager.storageURL)
    let additions = [
      Snippet(trigger: "one", expansion: "1"),
      Snippet(trigger: "two", expansion: "2"),
      Snippet(trigger: "three", expansion: "   \n"),
    ]

    #expect(throws: SnippetValidationError.expansionEmpty) {
      try manager.importSnippets(additions, reviewedAgainst: [existing])
    }

    #expect(try Data(contentsOf: manager.storageURL) == bytes)
    let reloaded = manager.load()
    #expect(reloaded.snippets.map(\.id) == [existing.id])
    #expect(reloaded.generation == saved.generation)
  }

  @Test("A trigger nobody can say is refused")
  func unspeakableTriggerRefused() throws {
    let manager = makeManager()
    #expect(throws: SnippetValidationError.triggerEmpty) {
      try manager.importSnippets(
        [Snippet(trigger: "...", expansion: "dots")], reviewedAgainst: [])
    }
  }

  @Test("A collision with an existing snippet is refused and names the one that has it")
  func collisionWithExistingRefused() throws {
    let manager = makeManager()
    let existing = Snippet(trigger: "My Email", expansion: "sam@example.com")
    try manager.upsert(existing)

    #expect(throws: SnippetValidationError.duplicateTrigger(existing: "My Email")) {
      try manager.importSnippets(
        [Snippet(trigger: "my   email", expansion: "other@example.com")],
        reviewedAgainst: [existing])
    }
    #expect(manager.load().snippets.count == 1)
  }

  @Test("Two additions on the same spoken words are refused, naming the earlier one")
  func collisionInsideTheBatchRefused() throws {
    let manager = makeManager()
    let first = Snippet(trigger: "sign off", expansion: "Best")
    let second = Snippet(trigger: "Sign Off!", expansion: "Cheers")

    #expect(throws: SnippetValidationError.duplicateTrigger(existing: "sign off")) {
      try manager.importSnippets([first, second], reviewedAgainst: [])
    }
    #expect(!FileManager.default.fileExists(atPath: manager.storageURL.path))
  }

  @Test("A baseline that no longer matches disk is refused without writing")
  func staleBaselineRefused() throws {
    let manager = makeManager()
    let existing = Snippet(trigger: "my email", expansion: "sam@example.com")
    try manager.upsert(existing)
    let addition = Snippet(trigger: "sig", expansion: "hi")

    // Review was built before `existing` was saved by another process.
    #expect(throws: SnippetStoreError.listChangedDuringReview) {
      try manager.importSnippets([addition], reviewedAgainst: [])
    }
    // Same id and trigger, but the expansion was edited meanwhile.
    var edited = existing
    edited.expansion = "old@example.com"
    #expect(throws: SnippetStoreError.listChangedDuringReview) {
      try manager.importSnippets([addition], reviewedAgainst: [edited])
    }
    // A snippet deleted since review.
    let gone = Snippet(trigger: "gone", expansion: "x")
    #expect(throws: SnippetStoreError.listChangedDuringReview) {
      try manager.importSnippets([addition], reviewedAgainst: [existing, gone])
    }
    #expect(manager.load().snippets.map(\.id) == [existing.id])
  }

  /// A store file written by hand, outside the store's own rules. The tests below stage what
  /// the decoder accepts and `upsert` would have refused.
  private func writeStoreFile(_ manager: SnippetsManager, snippets: [Snippet]) throws {
    let file = SnippetsManager.StoredFile(
      version: SnippetsManager.currentVersion, keyword: "backslash", snippets: snippets)
    try FileManager.default.createDirectory(
      at: manager.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(file).write(to: manager.storageURL)
  }

  @Test("A file carrying the same entry twice is not the list the review saw once")
  func repeatedEntryOnDiskIsStale() throws {
    let manager = makeManager()
    let entry = Snippet(trigger: "my email", expansion: "sam@example.com")
    try writeStoreFile(manager, snippets: [entry, entry])
    let bytes = try Data(contentsOf: manager.storageURL)

    #expect(throws: SnippetStoreError.listChangedDuringReview) {
      try manager.importSnippets(
        [Snippet(trigger: "sig", expansion: "hi")], reviewedAgainst: [entry])
    }
    #expect(try Data(contentsOf: manager.storageURL) == bytes)
    let twice = try manager.importSnippets(
      [Snippet(trigger: "sig", expansion: "hi")], reviewedAgainst: [entry, entry])
    #expect(twice.addedIDs.count == 1)
  }

  @Test("Two on-disk entries on the same words: the collision names the first, as the edit sheet does")
  func collisionNamesTheFirstOwnerOnDisk() throws {
    let manager = makeManager()
    let first = Snippet(trigger: "My Email", expansion: "a")
    let second = Snippet(trigger: "my email", expansion: "b")
    try writeStoreFile(manager, snippets: [first, second])
    let addition = Snippet(trigger: "MY EMAIL", expansion: "c")

    #expect(throws: SnippetValidationError.duplicateTrigger(existing: "My Email")) {
      try manager.importSnippets([addition], reviewedAgainst: [first, second])
    }
    #expect(throws: SnippetValidationError.duplicateTrigger(existing: "My Email")) {
      try SnippetsManager.validate(addition, against: [first, second])
    }
  }

  @Test("The baseline compares id, trigger and text only: order and creation date do not matter")
  func baselineIgnoresOrderAndCreationDate() throws {
    let manager = makeManager()
    let one = Snippet(trigger: "one", expansion: "1")
    let two = Snippet(trigger: "two", expansion: "2")
    try manager.upsert(one)
    try manager.upsert(two)
    let sameButLater = Snippet(
      id: one.id, trigger: one.trigger, expansion: one.expansion,
      createdAt: one.createdAt.addingTimeInterval(3_600))

    let receipt = try manager.importSnippets(
      [Snippet(trigger: "sig", expansion: "hi")], reviewedAgainst: [sameButLater, two])

    #expect(receipt.addedIDs.count == 1)
    #expect(manager.load().snippets.count == 3)
  }

  @Test("A store that cannot be read refuses the import and keeps its bytes")
  func unreadableStoreRefused() throws {
    let manager = makeManager()
    // A file from a newer app is unknown data; the store reads it as unreadable.
    let newer = Data("{\"version\": 99, \"keyword\": \"backslash\", \"snippets\": []}".utf8)
    try FileManager.default.createDirectory(
      at: manager.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try newer.write(to: manager.storageURL)

    #expect(throws: SnippetStoreError.existingFileUnreadable) {
      try manager.importSnippets([Snippet(trigger: "sig", expansion: "hi")], reviewedAgainst: [])
    }
    #expect(try Data(contentsOf: manager.storageURL) == newer)
  }

  @Test("The publication read answers only for a readable file")
  func loadedVocabularyIsNilUnlessReadable() throws {
    let manager = makeManager()
    #expect(manager.loadedVocabulary() == nil)

    let saved = try manager.upsert(Snippet(trigger: "sig", expansion: "hi"))
    let loaded = try #require(manager.loadedVocabulary())
    #expect(loaded.snippets.map(\.id) == saved.snippets.map(\.id))
    #expect(loaded.generation == saved.generation)

    // A file from a newer app: unreadable, so nil rather than an empty list.
    try Data("{\"version\": 99, \"keyword\": \"backslash\", \"snippets\": []}".utf8)
      .write(to: manager.storageURL)
    #expect(manager.loadedVocabulary() == nil)
    #expect(manager.load().snippets.isEmpty, "load() answers empty here; the publisher must not use it")
  }
}

/// Plan §3a: the locked import at the ceiling, measured on the dev machine and SKIPPED on the
/// hosted runner (`CI` is set there). Elapsed times go to the test log; the bound is for THIS
/// Mac and proves nothing about the slowest supported one.
@Suite("Snippet store import at the ceiling (#2997)", .tags(.harnessContract))
struct SnippetsManagerImportCeilingTests {

  static var runsOnThisMachine: Bool {
    (ProcessInfo.processInfo.environment["CI"] ?? "").isEmpty
  }

  private func makeManager() -> SnippetsManager {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-snippets-ceiling-\(UUID().uuidString)", isDirectory: true)
    return SnippetsManager(fileURL: dir.appendingPathComponent("snippets.json"))
  }

  /// Unique maximum-length triggers: a distinct prefix, padded to exactly the trigger ceiling.
  private func maximalSnippets(_ count: Int, prefix: String) -> [Snippet] {
    (0..<count).map {
      let head = "\(prefix)\(String(format: "%06d", $0)) "
      let padding = String(
        repeating: "a", count: SnippetImportLimits.maximumTriggerScalars - head.unicodeScalars.count)
      let trigger = head + padding
      precondition(trigger.unicodeScalars.count == SnippetImportLimits.maximumTriggerScalars)
      return Snippet(trigger: trigger, expansion: "x")
    }
  }

  @Test(
    "5,000 maximal snippets commit against 5,000 and against 50,000 existing ones",
    .enabled(if: SnippetsManagerImportCeilingTests.runsOnThisMachine))
  func commitAtCeiling() throws {
    for existingCount in [5_000, 50_000] {
      let manager = makeManager()
      let existing = maximalSnippets(existingCount, prefix: "e")
      _ = try manager.importSnippets(existing, reviewedAgainst: [])
      let additions = maximalSnippets(SnippetImportLimits.maximumCandidates, prefix: "n")

      let started = ContinuousClock.now
      let receipt = try manager.importSnippets(additions, reviewedAgainst: existing)
      let elapsed = ContinuousClock.now - started

      #expect(receipt.addedIDs.count == SnippetImportLimits.maximumCandidates)
      #expect(receipt.vocabulary.snippets.count == existingCount + SnippetImportLimits.maximumCandidates)
      print("commitAtCeiling existing=\(existingCount) elapsed=\(elapsed)")
      #expect(elapsed < .seconds(10), Comment(rawValue: "existing=\(existingCount) took \(elapsed)"))
    }
  }
}
