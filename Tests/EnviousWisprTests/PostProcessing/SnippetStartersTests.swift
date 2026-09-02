import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #628 — the example snippets a fresh install starts with.
///
/// `.productOutcome`: the seed writes to the same file that holds the user's own snippets, so
/// the failure that matters is not "no examples appeared" but "examples appeared on top of
/// something", or "the ones I deleted came back". Both are the user's data, not ours.
@Suite("Starter snippets (#628)", .tags(.productOutcome))
struct SnippetStartersSeedingTests {

  private func makeStore() -> (SnippetsManager, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-snip-seed-\(UUID().uuidString)", isDirectory: true)
    let url = dir.appendingPathComponent("snippets.json")
    return (SnippetsManager(fileURL: url), url)
  }

  // MARK: - The first launch

  @Test("A first launch returns the starters and leaves them on disk")
  func firstLaunchSeeds() throws {
    let (manager, url) = makeStore()

    let seeded = manager.loadOrSeedStarters()

    #expect(seeded.snippets.map(\.trigger) == SnippetStarters.all.map(\.trigger))
    // The oracle is the FILE. A seed that only populated memory would put the examples back on
    // every launch, and the user's deletions would never stick.
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(manager.load().snippets.count == SnippetStarters.all.count)
  }

  @Test("The seeded keyword is the default, so the examples can actually fire")
  func seedCarriesTheDefaultKeyword() {
    let (manager, _) = makeStore()

    let seeded = manager.loadOrSeedStarters()

    #expect(seeded.keyword == SnippetVocabulary.defaultKeyword)
    #expect(seeded.canFire)
  }

  // MARK: - The second launch, which is where a re-seed would show up

  @Test("Deleting every starter is remembered; they are not put back")
  func deletingThemAllSticks() throws {
    let (manager, _) = makeStore()
    let seeded = manager.loadOrSeedStarters()
    for snippet in seeded.snippets { try manager.remove(id: snippet.id) }

    let afterRelaunch = manager.loadOrSeedStarters()

    #expect(afterRelaunch.snippets.isEmpty)
  }

  @Test("A store that already has snippets is left exactly as it is")
  func existingStoreIsNotSeeded() throws {
    let (manager, _) = makeStore()
    try manager.upsert(Snippet(trigger: "my own", expansion: "mine"))

    let loaded = manager.loadOrSeedStarters()

    #expect(loaded.snippets.map(\.trigger) == ["my own"])
  }

  @Test("An edited starter stays edited across a relaunch")
  func editedStarterSurvives() throws {
    let (manager, _) = makeStore()
    let seeded = manager.loadOrSeedStarters()
    let first = try #require(seeded.snippets.first)
    try manager.upsert(
      Snippet(
        id: first.id, trigger: first.trigger, expansion: "real@enviouslabs.co",
        createdAt: first.createdAt))

    let afterRelaunch = manager.loadOrSeedStarters()

    let reloaded = try #require(afterRelaunch.snippets.first { $0.id == first.id })
    #expect(reloaded.expansion == "real@enviouslabs.co")
    #expect(!SnippetStarters.isUneditedExample(reloaded))
  }

  // MARK: - The case where seeding must not happen at all

  @Test("An unreadable file is never seeded over")
  func unreadableFileIsNotSeeded() throws {
    let (manager, url) = makeStore()
    try manager.upsert(Snippet(trigger: "my email", expansion: "sam@example.com"))
    let bytesBefore = try Data(contentsOf: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

    let loaded = manager.loadOrSeedStarters()

    #expect(loaded.snippets.isEmpty)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    #expect(try Data(contentsOf: url) == bytesBefore)
  }

  @Test("A corrupt store that was archived is not treated as a new install")
  func archivedCorruptionIsNotSeeded() throws {
    // Found by review, not imagined. `loadWhileLocked` archives a corrupt file and used to
    // report `.missing`, which reads exactly like a fresh install — so the seed would write six
    // John Doe examples into the one moment a user has just lost their own snippets, and they
    // would read as recovered content.
    let (manager, url) = makeStore()
    try manager.upsert(Snippet(trigger: "my email", expansion: "sam@example.com"))
    try Data("{ this is not json".utf8).write(to: url)

    let loaded = manager.loadOrSeedStarters()

    #expect(loaded.snippets.isEmpty)
    // And the archive still holds the bytes, so this is a recovery state rather than a loss.
    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: url.deletingLastPathComponent().path)
    #expect(siblings.filter { $0.contains("corrupted") }.count == 1)
  }

  @Test("The launch AFTER an archive still gets no examples")
  func archivedCorruptionSurvivesARelaunch() throws {
    // Round 1 fixed the call that does the archiving; this is the call after it, which is where
    // the state actually had to live. Archiving removed the file, and the file is the only
    // durable answer to "has this install ever had a store", so the repair is a tombstone on
    // disk rather than a value returned once.
    let (manager, url) = makeStore()
    try manager.upsert(Snippet(trigger: "my email", expansion: "sam@example.com"))
    try Data("{ this is not json".utf8).write(to: url)
    _ = manager.loadOrSeedStarters()

    // A second manager over the same path is what the next launch actually is.
    let afterRelaunch = SnippetsManager(fileURL: url).loadOrSeedStarters()

    #expect(afterRelaunch.snippets.isEmpty)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("After an archive the user can still save, and still gets no examples")
  func savingWorksAfterAnArchive() throws {
    let (manager, url) = makeStore()
    try manager.upsert(Snippet(trigger: "my email", expansion: "sam@example.com"))
    try Data("{ this is not json".utf8).write(to: url)
    _ = manager.loadOrSeedStarters()

    try manager.upsert(Snippet(trigger: "my new one", expansion: "typed after the archive"))

    #expect(manager.load().snippets.map(\.trigger) == ["my new one"])
  }

  // MARK: - The seeded list has to be editable

  @Test("Every starter can be saved back through the real store without a refusal")
  func seededListIsEditable() throws {
    let (manager, _) = makeStore()
    let seeded = manager.loadOrSeedStarters()

    // A colliding pair in the catalog would pass every load and then make the whole list
    // un-editable, because each save re-validates all of it against a clash the user never made.
    for snippet in seeded.snippets {
      try manager.upsert(snippet)
    }

    #expect(manager.load().snippets.count == SnippetStarters.all.count)
  }
}

/// #628 — the catalog itself, checked against the rules the edit sheet enforces.
///
/// `.driftGuard`: nothing at runtime re-checks a hardcoded list, so the day someone adds a
/// seventh starter is the day one of these properties can quietly stop holding.
@Suite("Starter snippet catalog (#628)", .tags(.driftGuard))
struct SnippetStartersCatalogTests {

  @Test("No two starters fire on the same spoken words")
  func noCollisions() {
    let all = SnippetStarters.all
    for (index, snippet) in all.enumerated() {
      for other in all[(index + 1)...] {
        #expect(!snippet.collidesWith(other), "\(snippet.trigger) collides with \(other.trigger)")
      }
    }
  }

  @Test("Every starter passes the store's own validation")
  func everyStarterIsValid() throws {
    let all = SnippetStarters.all
    for snippet in all {
      let others = all.filter { $0.id != snippet.id }
      try SnippetsManager.validate(snippet, against: others)
    }
  }

  @Test("The catalog holds exactly six starters, and every id string parses")
  func catalogIsSix() {
    // Building `all` is what forces every `UUID(uuidString:)` literal to be parsed. A typo in
    // one of them traps, and this is where that has to happen: the catalog is first touched
    // during app launch, so a malformed id that reached a release would be a launch crash for
    // a decorative feature. The count is pinned so adding a seventh is a deliberate edit.
    #expect(SnippetStarters.all.count == 6)
  }

  @Test("Every starter id is unique")
  func idsAreUnique() {
    let ids = SnippetStarters.all.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test("No starter expansion contains a newline")
  func everyExpansionIsOneLine() {
    // A snippet carrying a newline is delivered to the clipboard rather than typed in place.
    // Correct, and a poor first impression: the example would look like it did nothing.
    for snippet in SnippetStarters.all {
      // Computed outside `#expect`: `contains(where:)` is `rethrows`, and the macro expansion
      // does not carry the `try` the compiler then asks for.
      let carriesNewline = snippet.expansion.contains(where: \.isNewline)
      #expect(!carriesNewline, "\(snippet.trigger) would be delivered to the clipboard")
    }
  }

  @Test("Every trigger survives normalisation as the words it is written as")
  func triggersNormaliseToThemselves() {
    // Written lowercase and unpunctuated on purpose. A trigger that normalised to something
    // else would still match, but the row would show one thing and the user would have to say
    // another.
    for snippet in SnippetStarters.all {
      #expect(snippet.triggerTokens == snippet.trigger.split(separator: " ").map(String.init))
    }
  }

  @Test("Every starter is more than one spoken word after the keyword")
  func triggersAreNotSingleWords() {
    // A one-word trigger is the easiest kind to fire by accident, and the examples are the
    // pattern a user copies when they write their own.
    for snippet in SnippetStarters.all {
      #expect(snippet.triggerTokens.count >= 2, "\(snippet.trigger) is a single word")
    }
  }

  // MARK: - The badge

  @Test("An untouched starter is an example; a changed one is not")
  func badgeClearsOnEdit() throws {
    let starter = try #require(SnippetStarters.all.first)

    #expect(SnippetStarters.isUneditedExample(starter))
    #expect(
      !SnippetStarters.isUneditedExample(
        Snippet(id: starter.id, trigger: starter.trigger, expansion: "mine@example.com")))
    #expect(
      !SnippetStarters.isUneditedExample(
        Snippet(id: starter.id, trigger: "my work email", expansion: starter.expansion)))
  }

  @Test("A snippet the user wrote is never an example")
  func userSnippetIsNeverAnExample() {
    #expect(
      !SnippetStarters.isUneditedExample(
        Snippet(trigger: "my email", expansion: "john.doe@example.com")))
  }
}
