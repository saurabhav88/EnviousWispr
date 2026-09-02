import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #628 — the snippet store on disk.
///
/// `.productOutcome`: these snippets are typed by hand and exist nowhere else, so a store that
/// loses them, refuses to save them, or lets two of them fight over one trigger is a user
/// losing their own work. The corruption case matters most — it is the only one where the
/// wrong behaviour (overwrite in place) destroys data instead of merely reporting an error.
@Suite("Snippet store (#628)", .tags(.productOutcome))
struct SnippetsManagerTests {

  private func makeManager() -> SnippetsManager {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-snippets-\(UUID().uuidString)", isDirectory: true)
    return SnippetsManager(fileURL: dir.appendingPathComponent("snippets.json"))
  }

  // MARK: - The empty case, which every new install is

  @Test("A store with no file yet is empty and carries the default keyword")
  func missingFileIsAnEmptyStore() {
    let vocabulary = makeManager().load()

    #expect(vocabulary.snippets.isEmpty)
    #expect(vocabulary.keyword == SnippetVocabulary.defaultKeyword)
    #expect(vocabulary.canFire == false)
  }

  // MARK: - Round trip

  @Test("A saved snippet survives a reload, expansion byte-for-byte")
  func savedSnippetRoundTrips() throws {
    let manager = makeManager()
    let signoff = Snippet(trigger: "sign off", expansion: "Thanks,\nSam — Envious Labs")

    try manager.upsert(signoff)
    let reloaded = manager.load()

    #expect(reloaded.snippets.count == 1)
    // Newlines are the whole point of the sign-off case; a store that normalised them would
    // pass a shallower assertion.
    #expect(reloaded.snippets.first?.expansion == "Thanks,\nSam — Envious Labs")
    #expect(reloaded.canFire)
  }

  @Test("Editing a snippet updates it in place instead of adding a second one")
  func editUpdatesInPlace() throws {
    let manager = makeManager()
    var snippet = Snippet(trigger: "my email", expansion: "old@example.com")
    try manager.upsert(snippet)

    snippet.expansion = "new@example.com"
    try manager.upsert(snippet)

    let reloaded = manager.load()
    #expect(reloaded.snippets.count == 1)
    #expect(reloaded.snippets.first?.expansion == "new@example.com")
  }

  @Test("Removing a snippet leaves the rest")
  func removeLeavesTheRest() throws {
    let manager = makeManager()
    let keep = Snippet(trigger: "keep me", expansion: "kept")
    let drop = Snippet(trigger: "drop me", expansion: "dropped")
    try manager.upsert(keep)
    try manager.upsert(drop)

    try manager.remove(id: drop.id)

    #expect(manager.load().snippets.map(\.trigger) == ["keep me"])
  }

  // MARK: - The two Gate 2 refusals

  @Test("A snippet with no text to paste is refused")
  func emptyExpansionIsRefused() throws {
    let manager = makeManager()

    #expect(throws: SnippetValidationError.expansionEmpty) {
      try manager.upsert(Snippet(trigger: "my email", expansion: "   \n "))
    }
    #expect(manager.load().snippets.isEmpty)
  }

  @Test("A second snippet on the same spoken words is refused, and names the one that has it")
  func duplicateTriggerIsRefused() throws {
    let manager = makeManager()
    try manager.upsert(Snippet(trigger: "my email address", expansion: "one@example.com"))

    #expect(throws: SnippetValidationError.duplicateTrigger(existing: "my email address")) {
      // Different casing and a trailing full stop: the same spoken words.
      try manager.upsert(Snippet(trigger: "My Email Address.", expansion: "two@example.com"))
    }
    #expect(manager.load().snippets.count == 1)
  }

  /// The case a naive duplicate check gets wrong: editing a snippet must not collide with
  /// ITSELF. Without the id comparison in `validate`, saving an edit would be impossible.
  @Test("Editing a snippet does not collide with its own trigger")
  func editDoesNotSelfCollide() throws {
    let manager = makeManager()
    var snippet = Snippet(trigger: "my email address", expansion: "one@example.com")
    try manager.upsert(snippet)

    snippet.expansion = "two@example.com"
    #expect(throws: Never.self) { try manager.upsert(snippet) }
  }

  @Test("A trigger made only of punctuation is refused — nothing could ever match it")
  func punctuationOnlyTriggerIsRefused() throws {
    let manager = makeManager()

    #expect(throws: SnippetValidationError.triggerEmpty) {
      try manager.upsert(Snippet(trigger: "...", expansion: "something"))
    }
  }

  // MARK: - Keyword

  @Test("The keyword is stored and reloaded")
  func keywordRoundTrips() throws {
    let manager = makeManager()

    try manager.setKeyword("shortcut")

    #expect(manager.load().keyword == "shortcut")
  }

  @Test("Clearing the keyword field restores the default rather than disabling every snippet")
  func blankKeywordFallsBackToTheDefault() throws {
    let manager = makeManager()
    try manager.setKeyword("shortcut")

    try manager.setKeyword("   ")

    #expect(manager.load().keyword == SnippetVocabulary.defaultKeyword)
  }

  // MARK: - Durability

  /// The one case where the wrong behaviour destroys the user's work rather than reporting a
  /// failure. Assert the bytes are still on disk, not merely that loading did not crash.
  @Test("A corrupt file is archived, never overwritten, and the store starts empty")
  func corruptFileIsArchived() throws {
    let manager = makeManager()
    try manager.upsert(Snippet(trigger: "my email", expansion: "sam@example.com"))
    try Data("{ this is not json".utf8).write(to: manager.storageURL)

    let reloaded = manager.load()

    #expect(reloaded.snippets.isEmpty)
    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: manager.storageURL.deletingLastPathComponent().path)
    let archived = siblings.filter { $0.contains("corrupted") }
    #expect(archived.count == 1)
    let archivedURL = manager.storageURL.deletingLastPathComponent()
      .appendingPathComponent(try #require(archived.first))
    #expect(try String(contentsOf: archivedURL, encoding: .utf8) == "{ this is not json")
  }

  @Test("The store file is written 0600, not world-readable")
  func storeFileIsOwnerOnly() throws {
    let manager = makeManager()
    try manager.upsert(Snippet(trigger: "my email", expansion: "sam@example.com"))

    let attributes = try FileManager.default.attributesOfItem(atPath: manager.storageURL.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.int16Value == 0o600)
  }

  @Test("Every save advances the generation, so a stale lane read is detectable")
  func generationAdvancesOnEverySave() throws {
    let manager = makeManager()

    let first = try manager.upsert(Snippet(trigger: "one", expansion: "1"))
    let second = try manager.upsert(Snippet(trigger: "two", expansion: "2"))

    #expect(second.generation > first.generation)
  }
}
