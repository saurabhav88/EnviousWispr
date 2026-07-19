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
}
