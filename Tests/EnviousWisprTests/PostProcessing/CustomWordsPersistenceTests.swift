import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPostProcessing

/// #1646 (PR-P0) — fail-closed persistence. `loadFile()` distinguishes
/// missing / loaded / unreadable / corrupted, and every explicit CRUD mutation
/// throws without writing when an EXISTING file cannot be read, instead of
/// silently substituting an empty library and saving it over the real one.
@MainActor
@Suite("CustomWordsManager — fail-closed persistence (#1646)")
struct CustomWordsManagerPersistenceTests {
  // MARK: - Fixtures

  private static func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EnviousWispr-p0-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static func cleanup(_ dir: URL) {
    // Restore permissions first so removal never fails on a test-tightened dir/file.
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: dir.path)
    if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
      for item in contents {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o600],
          ofItemAtPath: dir.appendingPathComponent(item).path)
      }
    }
    try? FileManager.default.removeItem(at: dir)
  }

  /// A manager whose file already holds one user word ("Kubernetes").
  private static func seededManager() throws -> (
    manager: CustomWordsManager, url: URL, dir: URL, words: [CustomWord]
  ) {
    let dir = tempDir()
    let url = dir.appendingPathComponent("custom-words.json")
    let mgr = CustomWordsManager(fileURL: url)
    var words = mgr.load() ?? []
    try mgr.add(word: CustomWord(canonical: "Kubernetes"), to: &words)
    return (mgr, url, dir, words)
  }

  private static func chmod(_ url: URL, _ mode: Int) {
    try? FileManager.default.setAttributes(
      [.posixPermissions: mode], ofItemAtPath: url.path)
  }

  private static let garbage = Data("not valid json at all {{{".utf8)

  private static func corruptedSidecars(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
      .filter { $0.contains(".corrupted-") }
  }

  // MARK: - Missing file is a legitimate first run

  @Test("Missing file treats as first run across all eight call sites")
  func missingFileTreatsAsFirstRunAcrossAllEightCallSites() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let mgr = CustomWordsManager(fileURL: url)

    // load(): builtins only, no failure flag.
    var words = try #require(mgr.load())
    #expect(mgr.lastLoadFailure == nil)
    #expect(words.contains { $0.canonical == "EnviousWispr" })

    // All six CRUD mutations succeed against a missing file.
    try mgr.add(word: CustomWord(canonical: "Alpha Term"), to: &words)
    let batchIDs = try mgr.addBatch([CustomWord(canonical: "Beta Term")], to: &words)
    #expect(batchIDs.count == 1)
    let alpha = try #require(words.first { $0.canonical == "Alpha Term" })
    var updatedAlpha = alpha
    updatedAlpha.aliases = ["al fa"]
    try mgr.update(word: updatedAlpha, in: &words)
    try mgr.updateBatch([updatedAlpha], to: &words)
    try mgr.remove(id: alpha.id, from: &words)
    try mgr.removeBatch(ids: batchIDs, from: &words)
    #expect(!words.contains { $0.canonical == "Alpha Term" })
    #expect(!words.contains { $0.canonical == "Beta Term" })

    // flush with an unknown id: silently skipped, no crash, no file requirement.
    mgr.recordReplacements([UUID()])
    mgr.flushPendingIncrementsForTesting()
  }

  // MARK: - Unreadable existing file fails closed (the regression tests)

  @Test(
    "Unreadable existing file throws without writing",
    arguments: ["add", "addBatch", "remove", "removeBatch", "update", "updateBatch"])
  func unreadableExistingFileThrowsWithoutWriting(method: String) throws {
    let (mgr, url, dir, seeded) = try Self.seededManager()
    defer { Self.cleanup(dir) }
    let bytesBefore = try Data(contentsOf: url)
    var words = seeded
    let target = try #require(words.first { $0.canonical == "Kubernetes" })

    Self.chmod(url, 0o000)
    let error = #expect(throws: CustomWordsPersistenceError.self) {
      switch method {
      case "add":
        try mgr.add(word: CustomWord(canonical: "Terraform"), to: &words)
      case "addBatch":
        _ = try mgr.addBatch([CustomWord(canonical: "Terraform")], to: &words)
      case "remove":
        try mgr.remove(id: target.id, from: &words)
      case "removeBatch":
        try mgr.removeBatch(ids: [target.id], from: &words)
      case "update":
        try mgr.update(word: target, in: &words)
      case "updateBatch":
        try mgr.updateBatch([target], to: &words)
      default:
        Issue.record("unknown method \(method)")
      }
    }
    #expect(error == .unreadableExistingFile)

    // Caller's in-memory list untouched; on-disk bytes byte-identical.
    #expect(words == seeded)
    Self.chmod(url, 0o600)
    #expect(try Data(contentsOf: url) == bytesBefore)
  }

  @Test("Unreadable file keeps failing closed across repeated attempts")
  func unreadableFileKeepsFailingClosedAcrossRepeatedAttempts() throws {
    let (mgr, url, dir, seeded) = try Self.seededManager()
    defer { Self.cleanup(dir) }
    let bytesBefore = try Data(contentsOf: url)
    var words = seeded

    Self.chmod(url, 0o000)
    for _ in 0..<3 {
      #expect(throws: CustomWordsPersistenceError.unreadableExistingFile) {
        try mgr.add(word: CustomWord(canonical: "Terraform"), to: &words)
      }
    }
    #expect(words == seeded)
    Self.chmod(url, 0o600)
    #expect(try Data(contentsOf: url) == bytesBefore)

    // Once readable again, the same mutation succeeds — retry-safe forever.
    try mgr.add(word: CustomWord(canonical: "Terraform"), to: &words)
    #expect(words.contains { $0.canonical == "Terraform" })
  }

  // MARK: - Corrupted existing file: fails closed once, archives, self-heals

  @Test("Corrupted existing file throws without writing on first attempt")
  func corruptedExistingFileThrowsWithoutWritingOnFirstAttempt() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    try Self.garbage.write(to: url)
    let mgr = CustomWordsManager(fileURL: url)
    var words: [CustomWord] = []

    #expect(throws: CustomWordsPersistenceError.corruptedExistingFile) {
      try mgr.add(word: CustomWord(canonical: "Terraform"), to: &words)
    }
    #expect(words.isEmpty)
    // No new custom-words.json was written by the failed mutation.
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("Corrupted file still backs up before throwing")
  func corruptedFileStillBacksUpBeforeThrowing() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    try Self.garbage.write(to: url)
    let mgr = CustomWordsManager(fileURL: url)
    var words: [CustomWord] = []

    #expect(throws: CustomWordsPersistenceError.corruptedExistingFile) {
      try mgr.add(word: CustomWord(canonical: "Terraform"), to: &words)
    }
    let sidecars = Self.corruptedSidecars(in: dir)
    #expect(sidecars.count == 1)
    if let sidecar = sidecars.first {
      let archived = try Data(contentsOf: dir.appendingPathComponent(sidecar))
      #expect(archived == Self.garbage)
    }
  }

  @Test("Corrupted file self-heals on the next call after the first corruption encounter")
  func corruptedFileSelfHealsOnTheNextCallAfterTheFirstCorruptionEncounter() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    try Self.garbage.write(to: url)
    let mgr = CustomWordsManager(fileURL: url)
    var words: [CustomWord] = []

    // First encounter: a mutation — fails closed, archives.
    #expect(throws: CustomWordsPersistenceError.corruptedExistingFile) {
      try mgr.add(word: CustomWord(canonical: "Terraform"), to: &words)
    }
    // Second call of EITHER kind succeeds against a fresh empty file.
    words = try #require(mgr.load())
    #expect(mgr.lastLoadFailure == nil)
    try mgr.add(word: CustomWord(canonical: "Terraform"), to: &words)
    #expect(words.contains { $0.canonical == "Terraform" })
  }

  @Test("Second corruption uses a unique archive and self-heals again")
  func secondCorruptionUsesAUniqueArchiveAndSelfHealsAgain() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    try Self.garbage.write(to: url)
    let mgr = CustomWordsManager(fileURL: url)

    // First corruption encounter (a read) archives sidecar #1.
    #expect(mgr.load() == nil)
    #expect(Self.corruptedSidecars(in: dir).count == 1)

    // A later, unrelated corruption event must not collide with sidecar #1.
    try Data("different garbage <<<".utf8).write(to: url)
    #expect(mgr.load() == nil)
    #expect(Self.corruptedSidecars(in: dir).count == 2)

    // And it still self-heals.
    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Terraform"), to: &words)
    #expect(words.contains { $0.canonical == "Terraform" })
  }

  @Test("Corrupted archive failure keeps original and fails closed repeatedly")
  func corruptedArchiveFailureKeepsOriginalAndFailsClosedRepeatedly() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    try Self.garbage.write(to: url)
    let mgr = CustomWordsManager(fileURL: url)
    var words: [CustomWord] = []

    // Pre-create the companion lock while the directory is writable. This
    // fixture targets quarantine's archive-move failure, not lock creation.
    let lockURL = url.appendingPathExtension("lock")
    let lockCreated = FileManager.default.createFile(
      atPath: lockURL.path,
      contents: Data(),
      attributes: [.posixPermissions: 0o600]
    )
    try #require(lockCreated)

    // Read-only directory: the archive moveItem cannot succeed, so the result
    // must be .unreadable (permanently retry-safe), never a promised self-heal.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    for _ in 0..<2 {
      #expect(throws: CustomWordsPersistenceError.unreadableExistingFile) {
        try mgr.add(word: CustomWord(canonical: "Terraform"), to: &words)
      }
    }
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try Data(contentsOf: url) == Self.garbage)
    #expect(Self.corruptedSidecars(in: dir).isEmpty)
  }

  @Test("Launch load can archive corruption before next mutation proceeds")
  func launchLoadCanArchiveCorruptionBeforeNextMutationProceeds() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    try Self.garbage.write(to: url)
    let mgr = CustomWordsManager(fileURL: url)

    // Launch-style load consumes the one-time corruption encounter.
    #expect(mgr.load() == nil)
    #expect(mgr.lastLoadFailure == .corrupted)
    #expect(Self.corruptedSidecars(in: dir).count == 1)

    // The very next mutation sees .missing and proceeds cleanly — never throws.
    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Terraform"), to: &words)
    #expect(words.contains { $0.canonical == "Terraform" })
  }

  // MARK: - Legacy migrations unchanged

  @Test("Legacy [CustomWord] array format still migrates and loads")
  func legacyArrayFormatFileStillMigratesAndLoads() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let legacy = [CustomWord(canonical: "LegacyTerm")]
    try JSONEncoder().encode(legacy).write(to: url)
    let mgr = CustomWordsManager(fileURL: url)

    let words = try #require(mgr.load())
    #expect(mgr.lastLoadFailure == nil)
    #expect(words.contains { $0.canonical == "LegacyTerm" })
    // Re-saved in the versioned wrapper format.
    let migrated = try Data(contentsOf: url)
    #expect(String(data: migrated, encoding: .utf8)?.contains("\"version\"") == true)
  }

  @Test("Legacy [String] array format still migrates and loads")
  func legacyStringFormatFileStillMigratesAndLoads() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    try JSONEncoder().encode(["LegacyStringTerm", "  "]).write(to: url)
    let mgr = CustomWordsManager(fileURL: url)

    let words = try #require(mgr.load())
    #expect(words.contains { $0.canonical == "LegacyStringTerm" })
    #expect(!words.contains { $0.canonical.isEmpty })
  }

  // MARK: - Best-effort flush requeues

  @Test("flushPendingIncrements on unreadable file requeues instead of dropping")
  func flushPendingIncrementsOnUnreadableFileRequeuesInsteadOfDropping() throws {
    let (mgr, url, dir, seeded) = try Self.seededManager()
    defer { Self.cleanup(dir) }
    let target = try #require(seeded.first { $0.canonical == "Kubernetes" })

    mgr.recordReplacements([target.id])
    Self.chmod(url, 0o000)
    mgr.flushPendingIncrementsForTesting()  // requeued, not dropped

    Self.chmod(url, 0o600)
    mgr.flushPendingIncrementsForTesting()  // retried flush lands
    let words = try #require(mgr.load())
    let flushed = try #require(words.first { $0.id == target.id })
    #expect(flushed.frequencyUsed == 1)
  }

  // MARK: - load() contract

  @Test("load returns nil on unreadable or corrupted, unchanged")
  func loadReturnsNilOnUnreadableOrCorruptedUnchanged() throws {
    let (mgr, url, dir, _) = try Self.seededManager()
    defer { Self.cleanup(dir) }

    Self.chmod(url, 0o000)
    #expect(mgr.load() == nil)
    Self.chmod(url, 0o600)

    try Self.garbage.write(to: url)
    #expect(mgr.load() == nil)
  }

  @Test("load sets lastLoadFailure to unreadable or corrupted matching the real cause")
  func loadSetsLastLoadFailureToUnreadableOrCorruptedMatchingTheRealCause() throws {
    let (mgr, url, dir, _) = try Self.seededManager()
    defer { Self.cleanup(dir) }

    #expect(mgr.load() != nil)
    #expect(mgr.lastLoadFailure == nil)

    Self.chmod(url, 0o000)
    #expect(mgr.load() == nil)
    #expect(mgr.lastLoadFailure == .unreadable)
    Self.chmod(url, 0o600)

    try Self.garbage.write(to: url)
    #expect(mgr.load() == nil)
    #expect(mgr.lastLoadFailure == .corrupted)

    // Success clears the flag again (post-corruption self-heal).
    #expect(mgr.load() != nil)
    #expect(mgr.lastLoadFailure == nil)
  }

  @Test("Persistence error produces honest localized description")
  func persistenceErrorProducesHonestLocalizedDescription() {
    let unreadable = CustomWordsPersistenceError.unreadableExistingFile as Error
    #expect(unreadable.localizedDescription.contains("Nothing was changed"))
    let corrupted = CustomWordsPersistenceError.corruptedExistingFile as Error
    #expect(corrupted.localizedDescription.contains("moved aside for recovery"))
  }

  // MARK: - Learned provenance is valid at every write (#996)

  @Test("add and update keep only the learned marks that name a stored alias, in alias order, once")
  func addAndUpdatePruneMarksOutsideAliases() throws {
    let (mgr, _, dir, _) = try Self.seededManager()
    defer { Self.cleanup(dir) }
    var words = mgr.load() ?? []
    let learnedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let word = CustomWord(
      canonical: "Tuist", aliases: ["twist", "to-ist"], category: .brand, priority: 3,
      learnedAliases: ["to-ist", "ghost", "twist", "twist"], learnedAt: learnedAt)
    try mgr.add(word: word, to: &words)
    let added = try #require(words.first { $0.id == word.id })
    #expect(added.learnedAliases == ["twist", "to-ist"], "alias order, no ghost, no duplicate")
    #expect(added.learnedAt == learnedAt && added.category == .brand && added.priority == 3)
    // The user removes a chip in the edit sheet: the mark goes with it.
    var edited = added
    edited.aliases = ["to-ist"]
    try mgr.update(word: edited, in: &words)
    let updated = try #require(words.first { $0.id == word.id })
    #expect(updated.aliases == ["to-ist"] && updated.learnedAliases == ["to-ist"])
    #expect(updated.learnedAt == learnedAt, "learnedAt survives an edit")
    // What is on disk is what the live list says.
    let reloaded = try #require(mgr.load()?.first { $0.id == word.id })
    #expect(reloaded.learnedAliases == ["to-ist"] && reloaded.learnedAt == learnedAt)
  }

  @Test("a learned mark written as ' alias ' keeps its mark once the alias is stored as 'alias'")
  func trimmedAliasKeepsItsMark() throws {
    let (mgr, _, dir, _) = try Self.seededManager()
    defer { Self.cleanup(dir) }
    var words = mgr.load() ?? []
    let word = CustomWord(canonical: "Tuist", aliases: [" twist "], learnedAliases: [" twist "])
    try mgr.add(word: word, to: &words)
    let added = try #require(words.first { $0.id == word.id })
    #expect(added.aliases == ["twist"] && added.learnedAliases == ["twist"])
    // Case differs between the mark and the stored alias: the stored spelling
    // keeps the mark, once, and no case-only duplicate alias appears.
    let cased = CustomWord(canonical: "Saira", aliases: ["Sarah"], learnedAliases: [" sarah ", "SARAH"])
    try mgr.add(word: cased, to: &words)
    let addedCased = try #require(words.first { $0.id == cased.id })
    #expect(addedCased.aliases == ["Sarah"] && addedCased.learnedAliases == ["Sarah"])
  }

  @Test("sanitizeForPersistence is the one rule: it changes aliases and learned marks and nothing else")
  func sanitizeForPersistencePreservesEveryOtherField() {
    let learnedAt = Date(timeIntervalSince1970: 1_800_000_000)
    var word = CustomWord(
      canonical: "Tuist", aliases: [" twist ", "", "to-ist"], category: .brand, priority: 7,
      forceReplace: true, caseSensitive: true, source: .pack, frequencyUsed: 4,
      lastUsed: Date(timeIntervalSince1970: 5), minSimilarityOverride: 0.6,
      enrichmentPending: true, learnedAliases: ["twist", "nope"], learnedAt: learnedAt)
    word.enrichmentPending = true
    let out = CustomWordsManager.sanitizeForPersistence(word)
    #expect(out.aliases == ["twist", "to-ist"] && out.learnedAliases == ["twist"])
    #expect(out.id == word.id && out.canonical == "Tuist" && out.category == .brand)
    #expect(out.priority == 7 && out.forceReplace && out.caseSensitive && out.source == .pack)
    #expect(out.frequencyUsed == 4 && out.lastUsed == word.lastUsed)
    #expect(out.minSimilarityOverride == 0.6 && out.enrichmentPending && out.learnedAt == learnedAt)
  }

  // MARK: - A learned word over a deleted built-in (#996)

  @Test("restore-and-learn brings a deleted built-in back as ONE user word with the built-in's UUID, the sound-alike marked; re-delete puts the tombstone back")
  func restoreBuiltinAndLearnThenRedelete() throws {
    let (mgr, _, dir, _) = try Self.seededManager()
    defer { Self.cleanup(dir) }
    var words = mgr.load() ?? []
    let github = try #require(words.first { $0.canonical == "GitHub" })
    #expect(github.source == .builtin)
    try mgr.remove(id: github.id, from: &words)
    #expect(!words.contains { $0.canonical == "GitHub" }, "deleted built-in is hidden")

    let outcome = try mgr.restoreBuiltinAndLearn(canonical: "github", alias: " git-hub ")
    #expect(outcome.preState == .deletedBuiltin(id: github.id))
    #expect(outcome.word.id == github.id && outcome.word.source == .user)
    #expect(outcome.word.aliases == ["git hub", "get hub", "git-hub"])
    #expect(outcome.word.learnedAliases == ["git-hub"] && outcome.word.learnedAt == nil)
    let visible = outcome.words.filter { $0.canonical.caseInsensitiveCompare("GitHub") == .orderedSame }
    #expect(visible.count == 1 && visible.first == outcome.word, "one row, the override, never both")
    // The receipt's word is the persisted value: a fresh load agrees.
    #expect(try #require(mgr.load()).first { $0.id == github.id } == outcome.word)

    let after = try mgr.redeleteRestoredBuiltin(id: github.id)
    #expect(!after.contains { $0.canonical == "GitHub" })
    #expect(try #require(mgr.load()).contains { $0.canonical == "GitHub" } == false, "tombstone is back on disk")
    // Idempotent: a second re-delete changes nothing and throws nothing.
    let again = try mgr.redeleteRestoredBuiltin(id: github.id)
    #expect(again == after)
  }

  @Test("restore-and-learn refuses, writing nothing, when the built-in is not deleted, a user word claims the canonical, the canonical is not a built-in, or the alias is unstorable")
  func restoreBuiltinAndLearnRefusals() throws {
    let (mgr, url, dir, _) = try Self.seededManager()
    defer { Self.cleanup(dir) }
    var words = mgr.load() ?? []
    let before = try Data(contentsOf: url)
    // Not deleted.
    #expect(throws: CustomWordsPersistenceError.noRestorableBuiltin) {
      try mgr.restoreBuiltinAndLearn(canonical: "GitHub", alias: "git-hub")
    }
    // Not a built-in at all.
    #expect(throws: CustomWordsPersistenceError.noRestorableBuiltin) {
      try mgr.restoreBuiltinAndLearn(canonical: "Tuist", alias: "twist")
    }
    #expect(try Data(contentsOf: url) == before, "nothing written")
    // A user override claims the canonical (an edited built-in): not a
    // deleted built-in, so nothing to restore.
    let github = try #require(words.first { $0.canonical == "GitHub" })
    var edited = github
    edited.aliases = ["gh"]
    try mgr.update(word: edited, in: &words)
    #expect(try #require(words.first { $0.id == github.id }).source == .user)
    let claimed = try Data(contentsOf: url)
    #expect(throws: CustomWordsPersistenceError.noRestorableBuiltin) {
      try mgr.restoreBuiltinAndLearn(canonical: "GitHub", alias: "git-hub")
    }
    #expect(try Data(contentsOf: url) == claimed)
    // A tombstone AND an override for the same canonical on disk (a state
    // the manager's own doors never produce, so it is injected into the
    // JSON fixture): the override's claim wins and nothing is written.
    let sibling = CustomWordsManager(fileURL: url)
    var siblingWords = try #require(sibling.load())
    try sibling.remove(id: github.id, from: &siblingWords)  // tombstone, override gone
    let tombstoned = try Data(contentsOf: url)
    var document = try #require(JSONSerialization.jsonObject(with: tombstoned) as? [String: Any])
    var storedWords = try #require(document["words"] as? [[String: Any]])
    let encodedOverride = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any])
    storedWords.append(encodedOverride)
    document["words"] = storedWords
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
      .write(to: url, options: .atomic)
    let conflicted = try Data(contentsOf: url)
    #expect(throws: CustomWordsPersistenceError.noRestorableBuiltin) {
      try mgr.restoreBuiltinAndLearn(canonical: "GitHub", alias: "git-hub")
    }
    #expect(try Data(contentsOf: url) == conflicted)
    // Back to the plain tombstone: restore succeeds once, then a second call
    // refuses because the override now claims the canonical.
    try tombstoned.write(to: url, options: .atomic)
    _ = try mgr.restoreBuiltinAndLearn(canonical: "GitHub", alias: "git-hub")
    #expect(try Data(contentsOf: url) != tombstoned)
    let restoredBytes = try Data(contentsOf: url)
    #expect(throws: CustomWordsPersistenceError.noRestorableBuiltin) {
      try mgr.restoreBuiltinAndLearn(canonical: "GitHub", alias: "git-hub")
    }
    #expect(try Data(contentsOf: url) == restoredBytes)
    // Unstorable alias refuses before any lock, like every authoring door.
    #expect(throws: CustomWordsPersistenceError.unusableValue) {
      try mgr.restoreBuiltinAndLearn(canonical: "GitHub", alias: "   ")
    }
    #expect(try Data(contentsOf: url) == restoredBytes)
  }

  @Test("an unrelated word and tombstone written by another process between the two atomic operations survive both")
  func atomicOperationsStartFromFreshDiskState() throws {
    let (mgr, url, dir, _) = try Self.seededManager()
    defer { Self.cleanup(dir) }
    var words = mgr.load() ?? []
    let github = try #require(words.first { $0.canonical == "GitHub" })
    try mgr.remove(id: github.id, from: &words)
    // A sibling process adds a word and deletes another built-in behind our back.
    let sibling = CustomWordsManager(fileURL: url)
    var siblingWords = try #require(sibling.load())
    try sibling.add(word: CustomWord(canonical: "FromSibling"), to: &siblingWords)
    let chatgpt = try #require(siblingWords.first { $0.canonical == "ChatGPT" })
    try sibling.remove(id: chatgpt.id, from: &siblingWords)

    let outcome = try mgr.restoreBuiltinAndLearn(canonical: "GitHub", alias: "git-hub")
    #expect(outcome.words.contains { $0.canonical == "FromSibling" })
    #expect(!outcome.words.contains { $0.canonical == "ChatGPT" })
    let after = try mgr.redeleteRestoredBuiltin(id: github.id)
    #expect(after.contains { $0.canonical == "FromSibling" })
    #expect(!after.contains { $0.canonical == "ChatGPT" } && !after.contains { $0.canonical == "GitHub" })
  }

  @Test("removeUserOverride removes only the override of a live built-in, never tombstones it, leaves unrelated words and tombstones from fresh disk, and is a byte-identical no-op when absent; ordinary remove still tombstones")
  func removeUserOverrideRevealsTheBuiltin() throws {
    let (mgr, url, dir, _) = try Self.seededManager()
    defer { Self.cleanup(dir) }
    var words = mgr.load() ?? []
    let github = try #require(words.first { $0.canonical == "GitHub" })
    var edited = github
    edited.aliases = ["git hub", "get hub", "git-hub"]
    edited.learnedAliases = ["git-hub"]
    try mgr.update(word: edited, in: &words)
    #expect(try #require(words.first { $0.id == github.id }).source == .user, "an override exists")
    // A sibling writes an unrelated word and deletes another built-in meanwhile.
    let sibling = CustomWordsManager(fileURL: url)
    var siblingWords = try #require(sibling.load())
    try sibling.add(word: CustomWord(canonical: "FromSibling"), to: &siblingWords)
    let chatgpt = try #require(siblingWords.first { $0.canonical == "ChatGPT" })
    try sibling.remove(id: chatgpt.id, from: &siblingWords)

    let after = try mgr.removeUserOverride(id: github.id)
    let revealed = try #require(after.first { $0.id == github.id })
    #expect(revealed == github, "the shipped built-in shows again, exactly")
    #expect(after.contains { $0.canonical == "FromSibling" })
    #expect(!after.contains { $0.canonical == "ChatGPT" }, "the sibling's tombstone survives")
    let reloaded = try #require(mgr.load())
    #expect(reloaded.first { $0.id == github.id } == github, "no tombstone was written")
    let bytes = try Data(contentsOf: url)
    #expect(try mgr.removeUserOverride(id: github.id) == after, "absent override: same list")
    #expect(try Data(contentsOf: url) == bytes, "and nothing written")

    // Control: ordinary remove of the same word tombstones the built-in.
    var live = reloaded
    try mgr.remove(id: github.id, from: &live)
    #expect(!live.contains { $0.canonical == "GitHub" })

    // Control: an ordinary user word is not this method's to remove.
    let tuist = CustomWord(canonical: "Tuist")
    try mgr.add(word: tuist, to: &live)
    let before = try Data(contentsOf: url)
    let untouched = try mgr.removeUserOverride(id: tuist.id)
    #expect(untouched.contains { $0.id == tuist.id })
    #expect(try Data(contentsOf: url) == before, "byte-identical")
  }

  @Test("ordinary add still only restores a deleted built-in and discards the supplied aliases (unchanged behavior the learn path must avoid)")
  func ordinaryAddRestoreOnlyIsUnchanged() throws {
    let (mgr, _, dir, _) = try Self.seededManager()
    defer { Self.cleanup(dir) }
    var words = mgr.load() ?? []
    let github = try #require(words.first { $0.canonical == "GitHub" })
    try mgr.remove(id: github.id, from: &words)
    try mgr.add(word: CustomWord(canonical: "GitHub", aliases: ["git-hub"], learnedAliases: ["git-hub"]), to: &words)
    let restored = try #require(words.first { $0.canonical == "GitHub" })
    #expect(restored.source == .builtin && restored.aliases == ["git hub", "get hub"])
    #expect(restored.learnedAliases.isEmpty)
  }
}

/// #1646 (PR-P0) — coordinator surfaces the launch-time load failure honestly.
@MainActor
@Suite("CustomWordsCoordinator — launch load failure (#1646)")
struct CustomWordsCoordinatorLaunchFailureTests {
  private static func tempURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("EnviousWispr-p0c-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("custom-words.json")
  }

  private static func cleanup(_ url: URL) {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: url.path)
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  @Test("Unreadable file at launch sets wordsLoadFailure to unreadable with empty words, not error")
  func unreadableFileAtLaunchSetsWordsLoadFailureToUnreadableWithEmptyWordsNotError() throws {
    let url = Self.tempURL()
    defer { Self.cleanup(url) }
    let mgr = CustomWordsManager(fileURL: url)
    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Kubernetes"), to: &words)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: url.path)

    let coordinator = CustomWordsCoordinator(manager: mgr)
    #expect(coordinator.wordsLoadFailureAtLaunch == .unreadable)
    #expect(coordinator.customWords.isEmpty)
    #expect(coordinator.customWordError == nil)
  }

  @Test("Corrupted file at launch sets wordsLoadFailure to corrupted with empty words, not error")
  func corruptedFileAtLaunchSetsWordsLoadFailureToCorruptedWithEmptyWordsNotError() throws {
    let url = Self.tempURL()
    defer { Self.cleanup(url) }
    try Data("not valid json at all {{{".utf8).write(to: url)

    let coordinator = CustomWordsCoordinator(manager: CustomWordsManager(fileURL: url))
    #expect(coordinator.wordsLoadFailureAtLaunch == .corrupted)
    #expect(coordinator.customWords.isEmpty)
    #expect(coordinator.customWordError == nil)
  }

  @Test("Subsequent add after unreadable launch throws and touches no disk")
  func subsequentAddAfterUnreadableLaunchThrowsAndTouchesNoDisk() throws {
    let url = Self.tempURL()
    defer { Self.cleanup(url) }
    let mgr = CustomWordsManager(fileURL: url)
    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Kubernetes"), to: &words)
    let bytesBefore = try Data(contentsOf: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: url.path)

    let coordinator = CustomWordsCoordinator(manager: mgr)
    let error = coordinator.add(CustomWord(canonical: "Terraform"))
    #expect(error != nil)
    #expect(coordinator.customWordError == error)
    #expect(coordinator.customWords.isEmpty)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: url.path)
    #expect(try Data(contentsOf: url) == bytesBefore)
  }

  // MARK: - Export readability is a live question, not a launch snapshot (#1682)

  @Test("an unreadable file refuses the refresh and keeps the current list")
  func refreshFailsClosedWhileTheFileIsUnreadable() throws {
    let url = Self.tempURL()
    defer { Self.cleanup(url) }
    let mgr = CustomWordsManager(fileURL: url)
    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Kubernetes"), to: &words)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    let coordinator = CustomWordsCoordinator(manager: mgr)
    #expect(coordinator.wordsLoadFailureAtLaunch == .unreadable)
    #expect(coordinator.refreshFromDiskIfPossible() == false)
    #expect(coordinator.customWords.isEmpty)
  }

  @Test("a recovered file is ADOPTED, not merely reported readable")
  func refreshAdoptsTheRecoveredWordsRatherThanJustReportingReadable() throws {
    // The bug this freezes (cloud review, #1682): a readability check that
    // discarded what it read let export proceed while `customWords` was still
    // the empty launch fallback, so it wrote a valid EMPTY backup over a real
    // one. Reporting "readable" is not enough; the words have to arrive.
    let url = Self.tempURL()
    defer { Self.cleanup(url) }
    let mgr = CustomWordsManager(fileURL: url)
    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Kubernetes"), to: &words)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: url.path)

    let coordinator = CustomWordsCoordinator(manager: mgr)
    #expect(coordinator.customWords.isEmpty, "launch fallback while unreadable")

    // The file becomes readable again mid-session.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: url.path)

    #expect(coordinator.refreshFromDiskIfPossible())
    // The launch flag is a snapshot and stays set — which is exactly why it
    // was the wrong thing to gate on.
    #expect(coordinator.wordsLoadFailureAtLaunch == .unreadable)
    // The part that matters: the real words are now in hand, so an export
    // taken at this moment carries them instead of nothing.
    #expect(coordinator.customWords.contains { $0.canonical == "Kubernetes" })
  }

  // MARK: - Stale import commit refreshes the in-memory list (#1679 cloud review)

  @Test("a stale import commit refreshes the coordinator's list from disk")
  func staleImportCommitRefreshesTheCoordinatorsListFromDisk() throws {
    let url = Self.tempURL()
    defer { Self.cleanup(url) }
    let mgr = CustomWordsManager(fileURL: url)
    var seeded = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Qualtrics"), to: &seeded)

    let coordinator = CustomWordsCoordinator(manager: mgr)
    let baseline = coordinator.customWords
    #expect(baseline.contains { $0.canonical == "Qualtrics" })

    // Something outside this coordinator changes the file after Review was
    // built — another window, a restored backup, a second process.
    let outside = CustomWordsManager(fileURL: url)
    var outsideWords = try #require(outside.load())
    try outside.add(word: CustomWord(canonical: "Interloper"), to: &outsideWords)
    #expect(coordinator.customWords.contains { $0.canonical == "Interloper" } == false)

    let outcome = coordinator.commitImport(
      CustomWordsImportCommitPlan(
        baseline: CustomWordsImportLibrarySnapshot(words: baseline),
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")],
        replacements: []))

    #expect(outcome == .stale)
    // The whole point: the in-memory list must now match disk, so a rebuilt
    // review compares against reality instead of looping on the same stale copy.
    #expect(coordinator.customWords.contains { $0.canonical == "Interloper" })
    #expect(coordinator.customWords.contains { $0.canonical == "Kubernetes" } == false)
  }

  @Test("a stale commit against an unreadable file keeps the current list")
  func staleCommitAgainstAnUnreadableFileKeepsTheCurrentList() throws {
    let url = Self.tempURL()
    defer { Self.cleanup(url) }
    let mgr = CustomWordsManager(fileURL: url)
    var seeded = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Qualtrics"), to: &seeded)

    let coordinator = CustomWordsCoordinator(manager: mgr)
    let before = coordinator.customWords
    #expect(before.isEmpty == false)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    let outcome = coordinator.commitImport(
      CustomWordsImportCommitPlan(
        baseline: CustomWordsImportLibrarySnapshot(words: []),
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")],
        replacements: []))

    // Fails closed: an unreadable file must never clobber the live list with
    // an empty one on the way out of a failed commit.
    #expect(
      outcome
        != .committed(
          CustomWordsImportCommitReceipt(
            addedIDs: [], replacedIDs: [], droppedAliasCollisions: [])))
    #expect(coordinator.customWords == before)
  }

  @Test("a corrupted-and-archived library is not safe to export")
  func corruptedLibraryIsNotExportable() throws {
    // The scenario: the file is damaged at launch, so the manager archives it
    // aside. A later reload then sees a legitimately MISSING file and reports
    // a clean, empty library — which reads as success while the user's real
    // words sit in the archive. Exporting there writes an empty file over
    // whatever the user picked (cloud review, #1682).
    let url = Self.tempURL()
    defer { Self.cleanup(url) }
    try Data("not valid json at all {{{".utf8).write(to: url)

    let coordinator = CustomWordsCoordinator(manager: CustomWordsManager(fileURL: url))
    #expect(coordinator.wordsLoadFailureAtLaunch == .corrupted)

    // The reload succeeds — the damaged file is gone — and that is exactly why
    // readability alone cannot be the gate.
    #expect(coordinator.refreshFromDiskIfPossible())
    #expect(coordinator.canExportCurrentWords == false)
  }

  @Test("authoring a word after corruption makes the list exportable again")
  func authoringAWordAfterCorruptionRestoresExportability() throws {
    let url = Self.tempURL()
    defer { Self.cleanup(url) }
    try Data("not valid json at all {{{".utf8).write(to: url)

    let coordinator = CustomWordsCoordinator(manager: CustomWordsManager(fileURL: url))
    #expect(coordinator.canExportCurrentWords == false)

    // Once they have written something since, they have visibly accepted the
    // fresh start and the list is theirs again — blocking forever would be its
    // own kind of wrong.
    #expect(coordinator.add(CustomWord(canonical: "Kubernetes")) == nil)
    #expect(coordinator.canExportCurrentWords)
  }
}
