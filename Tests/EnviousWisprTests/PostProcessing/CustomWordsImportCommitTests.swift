import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #1665 (PR-F2b) — atomic import commit. Every test drives a real manager
/// against a temp file, so "one write or none" is verified against disk, not
/// a mock.
@MainActor
@Suite("CustomWordsImportCommit")
struct CustomWordsImportCommitTests {

  // MARK: - Harness

  private func makeManager() -> (CustomWordsManager, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-import-commit-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("custom-words.json")
    return (CustomWordsManager(fileURL: url), url)
  }

  /// Seeds user words and returns the effective list the coordinator would hold.
  private func seed(
    _ manager: CustomWordsManager, _ words: [CustomWord]
  ) throws -> [CustomWord] {
    var live = manager.load() ?? []
    _ = try manager.addBatch(words, to: &live)
    return live
  }

  private func candidate(
    _ canonical: String,
    aliases: CustomWordsImportField<[String]> = .unspecified,
    suggestedAliases: [String] = [],
    category: CustomWordsImportField<WordCategory> = .unspecified,
    priority: CustomWordsImportField<Int> = .unspecified,
    forceReplace: CustomWordsImportField<Bool> = .unspecified,
    caseSensitive: CustomWordsImportField<Bool> = .unspecified,
    minSimilarityOverride: CustomWordsImportField<Double?> = .unspecified
  ) -> CustomWordsImportCandidate {
    CustomWordsImportCandidate(
      canonical: canonical, aliases: aliases, suggestedAliases: suggestedAliases,
      category: category, priority: priority, forceReplace: forceReplace,
      caseSensitive: caseSensitive, minSimilarityOverride: minSimilarityOverride)
  }

  private func plan(
    baseline: [CustomWord],
    additions: [CustomWordsImportCandidate] = [],
    replacements: [CustomWordsImportReplacement] = []
  ) -> CustomWordsImportCommitPlan {
    CustomWordsImportCommitPlan(
      baseline: CustomWordsImportLibrarySnapshot(words: baseline),
      additions: additions, replacements: replacements)
  }

  // MARK: - Atomicity and staleness

  @Test("a mixed add and replace lands as one committed file state")
  func mixedAddAndReplaceUsesOneCommittedFileState() throws {
    let (manager, url) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Qualtrics")])
    let target = try #require(live.first { $0.canonical == "Qualtrics" })

    let receipt = try manager.commitImport(
      plan(
        baseline: live,
        additions: [candidate("Kubernetes")],
        replacements: [
          CustomWordsImportReplacement(
            existingID: target.id, candidate: candidate("Qualtrics XM"))
        ]),
      to: &live)

    #expect(receipt.addedIDs.count == 1)
    #expect(receipt.replacedIDs == [target.id])
    #expect(live.contains { $0.canonical == "Kubernetes" })
    #expect(live.contains { $0.canonical == "Qualtrics XM" })
    #expect(live.contains { $0.canonical == "Qualtrics" } == false)

    // Both changes are in the same on-disk state.
    let onDisk = try #require(CustomWordsManager(fileURL: url).load())
    #expect(onDisk.contains { $0.canonical == "Kubernetes" })
    #expect(onDisk.contains { $0.canonical == "Qualtrics XM" })
  }

  @Test("a replacement preserves the existing id and usage history")
  func replacementPreservesExistingIDAndUsageHistory() throws {
    let (manager, _) = makeManager()
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    var live = try seed(
      manager,
      [CustomWord(canonical: "Qualtrics", frequencyUsed: 7, lastUsed: stamp)])
    let target = try #require(live.first { $0.canonical == "Qualtrics" })

    _ = try manager.commitImport(
      plan(
        baseline: live,
        replacements: [
          CustomWordsImportReplacement(
            existingID: target.id, candidate: candidate("Qualtrics XM"))
        ]),
      to: &live)

    let updated = try #require(live.first { $0.id == target.id })
    #expect(updated.canonical == "Qualtrics XM")
    #expect(updated.frequencyUsed == 7)
    #expect(updated.lastUsed == stamp)
  }

  @Test("a semantic change under an open review returns stale without writing")
  func semanticLibraryChangeReturnsStaleWithoutWrite() throws {
    let (manager, url) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Qualtrics")])
    let staleBaseline = live

    // Someone edits the list after Review was built.
    _ = try seed(manager, [CustomWord(canonical: "Interloper")])
    var current = try #require(manager.load())

    #expect(throws: CustomWordsImportCommitError.staleLibrary) {
      _ = try manager.commitImport(
        plan(baseline: staleBaseline, additions: [candidate("Kubernetes")]),
        to: &current)
    }
    let onDisk = try #require(CustomWordsManager(fileURL: url).load())
    #expect(onDisk.contains { $0.canonical == "Kubernetes" } == false)
    live = onDisk
    #expect(live.isEmpty == false)
  }

  @Test("a usage-history-only change does not stale the review")
  func unrelatedUsageHistoryChangeDoesNotReturnStale() throws {
    let (manager, _) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Qualtrics")])
    let baseline = live

    // Same words, different usage counters — the snapshot excludes these.
    var bumped = live
    for index in bumped.indices {
      bumped[index].frequencyUsed += 3
      bumped[index].lastUsed = Date(timeIntervalSince1970: 1_700_000_000)
    }
    live = bumped

    let receipt = try manager.commitImport(
      plan(baseline: baseline, additions: [candidate("Kubernetes")]), to: &live)
    #expect(receipt.addedIDs.count == 1)
  }

  @Test("an all-skipped confirm writes nothing at all")
  func confirmWithAllSkippedWritesNothing() throws {
    let (manager, url) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Qualtrics")])
    let before = try Data(contentsOf: url)

    let receipt = try manager.commitImport(plan(baseline: live), to: &live)
    #expect(receipt.addedIDs.isEmpty)
    #expect(receipt.replacedIDs.isEmpty)
    #expect(try Data(contentsOf: url) == before)
    // No backup for a no-op commit.
    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: url.deletingLastPathComponent().path)
    #expect(siblings.contains { $0.hasPrefix("custom-words.backup-") } == false)
  }

  @Test("no existing file is a legitimate first import")
  func noExistingFileTreatsCommitAsFirstImport() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    let receipt = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)
    #expect(receipt.addedIDs.count == 1)
    #expect(live.contains { $0.canonical == "Kubernetes" })
  }

  @Test("a plan naming a word that is not in the library is rejected")
  func planReferencingAnUnknownWordIsRejected() throws {
    let (manager, _) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Qualtrics")])
    #expect(throws: CustomWordsImportCommitError.invalidPlan) {
      _ = try manager.commitImport(
        plan(
          baseline: live,
          replacements: [
            CustomWordsImportReplacement(existingID: UUID(), candidate: candidate("Nope"))
          ]),
        to: &live)
    }
  }

  // MARK: - Field-level Replace semantics

  @Test("replace with unspecified fields preserves every hand-tuned value")
  func replaceWithUnspecifiedFieldsPreservesExistingConfiguration() throws {
    let (manager, _) = makeManager()
    var live = try seed(
      manager,
      [
        CustomWord(
          canonical: "Qualtrics", aliases: ["qualtrix"], category: .brand, priority: 5,
          forceReplace: true, caseSensitive: true, minSimilarityOverride: 0.9)
      ])
    let target = try #require(live.first { $0.canonical == "Qualtrics" })

    _ = try manager.commitImport(
      plan(
        baseline: live,
        replacements: [
          CustomWordsImportReplacement(
            existingID: target.id, candidate: candidate("Qualtrics XM"))
        ]),
      to: &live)

    let updated = try #require(live.first { $0.id == target.id })
    #expect(updated.canonical == "Qualtrics XM")  // canonical is always taken
    #expect(updated.aliases == ["qualtrix"])
    #expect(updated.category == .brand)
    #expect(updated.priority == 5)
    #expect(updated.forceReplace == true)
    #expect(updated.caseSensitive == true)
    #expect(updated.minSimilarityOverride == 0.9)
  }

  @Test("replace with supplied fields overwrites the existing values")
  func replaceWithSuppliedFieldsOverwritesExisting() throws {
    let (manager, _) = makeManager()
    var live = try seed(
      manager,
      [
        CustomWord(
          canonical: "Qualtrics", aliases: ["qualtrix"], category: .brand, priority: 5,
          forceReplace: true, caseSensitive: true, minSimilarityOverride: 0.9)
      ])
    let target = try #require(live.first { $0.canonical == "Qualtrics" })

    _ = try manager.commitImport(
      plan(
        baseline: live,
        replacements: [
          CustomWordsImportReplacement(
            existingID: target.id,
            candidate: candidate(
              "Qualtrics", aliases: .supplied(["qxm"]), category: .supplied(.general),
              priority: .supplied(1), forceReplace: .supplied(false),
              caseSensitive: .supplied(false), minSimilarityOverride: .supplied(0.5)))
        ]),
      to: &live)

    let updated = try #require(live.first { $0.id == target.id })
    #expect(updated.aliases == ["qxm"])
    #expect(updated.category == .general)
    #expect(updated.priority == 1)
    #expect(updated.forceReplace == false)
    #expect(updated.caseSensitive == false)
    #expect(updated.minSimilarityOverride == 0.5)
  }

  @Test("only the backup format can authoritatively clear aliases and strictness")
  func suppliedEmptyAndSuppliedNilDeliberatelyClear() throws {
    let (manager, _) = makeManager()
    var live = try seed(
      manager,
      [CustomWord(canonical: "Qualtrics", aliases: ["qualtrix"], minSimilarityOverride: 0.9)])
    let target = try #require(live.first { $0.canonical == "Qualtrics" })

    _ = try manager.commitImport(
      plan(
        baseline: live,
        replacements: [
          CustomWordsImportReplacement(
            existingID: target.id,
            candidate: candidate(
              "Qualtrics", aliases: .supplied([]), minSimilarityOverride: .supplied(nil)))
        ]),
      to: &live)

    let updated = try #require(live.first { $0.id == target.id })
    #expect(updated.aliases.isEmpty)
    #expect(updated.minSimilarityOverride == nil)
  }

  @Test("AI suggestions never apply on replace")
  func suggestedAliasesNeverApplyOnReplace() throws {
    let (manager, _) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Qualtrics", aliases: ["qualtrix"])])
    let target = try #require(live.first { $0.canonical == "Qualtrics" })

    _ = try manager.commitImport(
      plan(
        baseline: live,
        replacements: [
          CustomWordsImportReplacement(
            existingID: target.id,
            candidate: candidate("Qualtrics", suggestedAliases: ["kwaltrics"]))
        ]),
      to: &live)

    let updated = try #require(live.first { $0.id == target.id })
    #expect(updated.aliases == ["qualtrix"])
  }

  @Test("an addition unions source and suggested aliases, source spellings first")
  func additionUnionsSourceAndSuggestedAliasesDeduplicated() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(
        baseline: live,
        additions: [
          candidate(
            "Qualtrics", aliases: .supplied(["qualtrix"]),
            suggestedAliases: ["QUALTRIX", "kwaltrics"])
        ]),
      to: &live)

    let added = try #require(live.first { $0.canonical == "Qualtrics" })
    // QUALTRIX deduplicates against the source spelling, which wins.
    #expect(added.aliases == ["qualtrix", "kwaltrics"])
  }

  @Test("an addition with unspecified fields falls back to the type defaults")
  func additionWithUnspecifiedFieldsFallsBackToTypeDefaults() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)

    let added = try #require(live.first { $0.canonical == "Kubernetes" })
    #expect(added.category == .general)
    #expect(added.priority == 0)
    #expect(added.forceReplace == false)
    #expect(added.caseSensitive == false)
    #expect(added.minSimilarityOverride == nil)
    #expect(added.aliases.isEmpty)
  }

  // MARK: - Alias enforcement

  @Test("an alias already held by another word is dropped, not the word")
  func collidingAliasIsDroppedNotWordOnCommit() throws {
    let (manager, _) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Anika", aliases: ["annie"])])

    let receipt = try manager.commitImport(
      plan(
        baseline: live,
        additions: [candidate("Annabelle", aliases: .supplied(["Annie", "belle"]))]),
      to: &live)

    let added = try #require(live.first { $0.canonical == "Annabelle" })
    #expect(added.aliases == ["belle"])  // the word survives, the alias does not
    #expect(receipt.droppedAliasCollisions.map(\.alias) == ["Annie"])
  }

  @Test("an untouched incumbent alias always beats an imported one")
  func incumbentLibraryAliasAlwaysWinsOverImportedAlias() throws {
    let (manager, _) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Anika", aliases: ["annie"])])
    let incumbent = try #require(live.first { $0.canonical == "Anika" })

    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Zed", aliases: .supplied(["annie"]))]),
      to: &live)

    let untouched = try #require(live.first { $0.id == incumbent.id })
    #expect(untouched.aliases == ["annie"])  // never edited by the import
    let added = try #require(live.first { $0.canonical == "Zed" })
    #expect(added.aliases.isEmpty)
  }

  @Test("when two new words share an alias the first in plan order keeps it")
  func firstCandidateInPlanOrderWinsWhenTwoNewCandidatesShareAnAlias() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    let receipt = try manager.commitImport(
      plan(
        baseline: live,
        additions: [
          candidate("Anika", aliases: .supplied(["annie"])),
          candidate("Annabelle", aliases: .supplied(["Annie"])),
        ]),
      to: &live)

    #expect(try #require(live.first { $0.canonical == "Anika" }).aliases == ["annie"])
    #expect(try #require(live.first { $0.canonical == "Annabelle" }).aliases.isEmpty)
    #expect(receipt.droppedAliasCollisions.map(\.alias) == ["Annie"])
  }

  @Test("an alias equal to another word's canonical is dropped")
  func importedAliasCollidingWithAnotherCanonicalDropsTheAlias() throws {
    let (manager, _) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Anika")])
    let receipt = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Zed", aliases: .supplied(["anika"]))]),
      to: &live)

    #expect(try #require(live.first { $0.canonical == "Zed" }).aliases.isEmpty)
    #expect(receipt.droppedAliasCollisions.count == 1)
  }

  @Test("an alias equal to its own canonical is removed silently, not reported")
  func aliasEqualToItsOwnCanonicalIsSilentlyRemovedNotReportedAsADrop() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    let receipt = try manager.commitImport(
      plan(
        baseline: live,
        additions: [candidate("Anika", aliases: .supplied(["ANIKA", "annie"]))]),
      to: &live)

    #expect(try #require(live.first { $0.canonical == "Anika" }).aliases == ["annie"])
    #expect(receipt.droppedAliasCollisions.isEmpty)
  }

  @Test("two replacements sharing an alias are both covered by enforcement")
  func twoReplacementsSharingAnAliasKeepOnlyTheFirstInPlanOrder() throws {
    let (manager, _) = makeManager()
    var live = try seed(
      manager, [CustomWord(canonical: "First"), CustomWord(canonical: "Second")])
    let first = try #require(live.first { $0.canonical == "First" })
    let second = try #require(live.first { $0.canonical == "Second" })

    let receipt = try manager.commitImport(
      plan(
        baseline: live,
        replacements: [
          CustomWordsImportReplacement(
            existingID: first.id,
            candidate: candidate("First", aliases: .supplied(["shared"]))),
          CustomWordsImportReplacement(
            existingID: second.id,
            candidate: candidate("Second", aliases: .supplied(["Shared"]))),
        ]),
      to: &live)

    #expect(try #require(live.first { $0.id == first.id }).aliases == ["shared"])
    #expect(try #require(live.first { $0.id == second.id }).aliases.isEmpty)
    #expect(receipt.droppedAliasCollisions.map(\.alias) == ["Shared"])
  }

  @Test("two replacements aimed at the same word are rejected without writing")
  func repeatedReplacementTargetIsRejected() throws {
    let (manager, url) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Qualtrics")])
    let target = try #require(live.first { $0.canonical == "Qualtrics" })
    let before = try Data(contentsOf: url)

    #expect(throws: CustomWordsImportCommitError.invalidPlan) {
      _ = try manager.commitImport(
        self.plan(
          baseline: live,
          replacements: [
            CustomWordsImportReplacement(
              existingID: target.id, candidate: self.candidate("First Win")),
            CustomWordsImportReplacement(
              existingID: target.id, candidate: self.candidate("Second Win")),
          ]),
        to: &live)
    }
    // Both would have applied against the same original entry, so the later one
    // would silently win an import the user never approved.
    #expect(try Data(contentsOf: url) == before)
  }

  @Test("a shared alias resolves by plan order, not by storage order")
  func sharedAliasBetweenReplacementsResolvesByPlanOrderNotStorageOrder() throws {
    let (manager, _) = makeManager()
    var live = try seed(
      manager, [CustomWord(canonical: "Alpha"), CustomWord(canonical: "Zeta")])
    let alpha = try #require(live.first { $0.canonical == "Alpha" })
    let zeta = try #require(live.first { $0.canonical == "Zeta" })

    // Plan order is deliberately the REVERSE of storage order, so a resolver
    // walking the stored library would keep the wrong claimant.
    let receipt = try manager.commitImport(
      plan(
        baseline: live,
        replacements: [
          CustomWordsImportReplacement(
            existingID: zeta.id, candidate: candidate("Zeta", aliases: .supplied(["shared"]))),
          CustomWordsImportReplacement(
            existingID: alpha.id, candidate: candidate("Alpha", aliases: .supplied(["Shared"]))),
        ]),
      to: &live)

    #expect(try #require(live.first { $0.id == zeta.id }).aliases == ["shared"])
    #expect(try #require(live.first { $0.id == alpha.id }).aliases.isEmpty)
    #expect(receipt.droppedAliasCollisions.map(\.alias) == ["Shared"])
  }

  @Test("when two untouched words share an alias the receipt names the runtime winner")
  func receiptNamesTheRuntimeWinningIncumbentAliasOwner() throws {
    let (manager, _) = makeManager()
    var live = try seed(
      manager,
      [
        CustomWord(canonical: "Earlier", aliases: ["annie"]),
        CustomWord(canonical: "Later", aliases: ["annie"]),
      ])
    let later = try #require(live.first { $0.canonical == "Later" })

    let receipt = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Zed", aliases: .supplied(["Annie"]))]),
      to: &live)

    // WordCorrector assigns aliases unconditionally, so the LATER word holds
    // the trigger at runtime — naming the earlier one would misinform.
    #expect(receipt.droppedAliasCollisions.map(\.heldBy) == [later.id])
  }

  @Test("commit failures carry an honest user-facing message")
  func commitErrorsHaveLocalizedDescriptions() {
    for error in [
      CustomWordsImportCommitError.staleLibrary,
      .invalidPlan,
      .unreadableLibrary,
    ] {
      let message = error.localizedDescription
      #expect(message.isEmpty == false)
      // Every one must state that nothing was applied, and must not fall back
      // to Foundation's generic text.
      #expect(message.lowercased().contains("nothing"))
      #expect(message.contains("couldn’t be completed") == false)
    }
  }

  @Test("a second commit in the same second does not destroy the first backup")
  func backupsInTheSameSecondDoNotOverwriteEachOther() throws {
    let (manager, url) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Original")])

    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("First")]), to: &live)
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Second")]), to: &live)

    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: url.deletingLastPathComponent().path)
    let backups = siblings.filter { $0.hasPrefix("custom-words.backup-") }
    #expect(backups.count == 2)

    // The oldest backup must still hold the true pre-import state.
    let states = try backups.map { name -> [String] in
      let backupURL = url.deletingLastPathComponent().appendingPathComponent(name)
      let loaded = try #require(CustomWordsManager(fileURL: backupURL).load())
      return loaded.map(\.canonical)
    }
    #expect(states.contains { $0.contains("Original") && !$0.contains("First") })
  }

  // MARK: - Built-ins

  @Test("replacing a built-in leaves exactly one word, not the built-in plus an override")
  func replacingABuiltinRetiresTheBuiltinInsteadOfDuplicatingIt() throws {
    let (manager, _) = makeManager()
    var live = try #require(manager.load())
    let builtin = try #require(live.first)
    let originalCount = live.count

    _ = try manager.commitImport(
      plan(
        baseline: live,
        replacements: [
          CustomWordsImportReplacement(
            existingID: builtin.id,
            candidate: candidate("\(builtin.canonical) Renamed"))
        ]),
      to: &live)

    #expect(live.count == originalCount)
    #expect(live.contains { $0.canonical == "\(builtin.canonical) Renamed" })
    #expect(live.contains { $0.canonical == builtin.canonical } == false)
  }

  // MARK: - Backup

  @Test("a changing commit writes a backup first")
  func backupFileWrittenBeforeNonEmptyCommit() throws {
    let (manager, url) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Qualtrics")])
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)

    let siblings = try FileManager.default.contentsOfDirectory(
      atPath: url.deletingLastPathComponent().path)
    let backups = siblings.filter { $0.hasPrefix("custom-words.backup-") }
    #expect(backups.count == 1)

    // The backup holds the PRE-commit state.
    let backupURL = url.deletingLastPathComponent().appendingPathComponent(backups[0])
    let backed = try #require(CustomWordsManager(fileURL: backupURL).load())
    #expect(backed.contains { $0.canonical == "Kubernetes" } == false)
    #expect(backed.contains { $0.canonical == "Qualtrics" })
  }
}
