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

  @Test("an alias matching a multi-word canonical's space-free form is dropped with a receipt")
  func aliasCollidingOnTheNoSpaceSurfaceIsDroppedOnCommit() throws {
    // #1667's acceptance criterion, and the half the compare screen cannot
    // deliver on its own. `Claude Code` claims `claudecode` on the compound
    // surface, so this alias could never fire. Enforcement here used to key on
    // `importPersistenceKey`, which has no compound surface at all, so the
    // alias was KEPT — the review screen disclosed a collision and the commit
    // saved the alias anyway. Both sides now read one authority.
    let (manager, _) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Claude Code")])

    let receipt = try manager.commitImport(
      plan(
        baseline: live,
        additions: [candidate("Zed", aliases: .supplied(["claudecode", "zeddy"]))]),
      to: &live)

    let added = try #require(live.first { $0.canonical == "Zed" })
    #expect(added.aliases == ["zeddy"], "the inert alias must not be persisted")
    #expect(receipt.droppedAliasCollisions.map(\.alias) == ["claudecode"])
    let owner = try #require(live.first { $0.canonical == "Claude Code" })
    #expect(receipt.droppedAliasCollisions.map(\.heldBy) == [owner.id])
  }

  @Test("a newly imported multi-word canonical takes the compound key from an older alias")
  func importedCanonicalOverwritesAnIncumbentCompoundAlias() throws {
    // The compound namespace is the one place a canonical is written
    // UNCONDITIONALLY, so it takes the key from an existing alias. Registering
    // touched canonicals as gap-fill instead named the older word as owner,
    // which is not who holds the trigger once the import lands (grounded
    // review r4).
    //
    // Anika's alias claims "claudecode". Importing the word `Claude Code`
    // overwrites that slot, so a second imported alias of the same spelling
    // must be refused in the NAME OF THE NEW WORD, not Anika's.
    let (manager, _) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Anika", aliases: ["claudecode"])])

    let receipt = try manager.commitImport(
      plan(
        baseline: live,
        additions: [
          candidate("Claude Code"),
          candidate("Zed", aliases: .supplied(["claudecode"])),
        ]),
      to: &live)

    let newOwner = try #require(live.first { $0.canonical == "Claude Code" })
    #expect(receipt.droppedAliasCollisions.map(\.alias) == ["claudecode"])
    #expect(
      receipt.droppedAliasCollisions.map(\.heldBy) == [newOwner.id],
      "the incoming canonical owns the compound key, not the older alias")
  }

  @Test("touched canonicals resolve the compound key in FINAL storage order, not apply order")
  func touchedCanonicalCompoundOwnershipMatchesRuntimeStorageOrder() throws {
    // Corrected in round 7, reversing round 6's own conclusion. r6 reasoned
    // that the plan's APPLY order should decide a shared compound key, since
    // that is the order the user approved. That reasoning was never checked
    // against the real corrector.
    //
    // It is wrong. `WordCorrector.buildExactTriggerIndex` — the actual runtime
    // authority — resolves the compound namespace by iterating whatever array
    // it is HANDED, in that array's order, last-write-wins. Replacements update
    // an existing word's STORAGE POSITION in place; they do not move it. So
    // the array the corrector will build its lookups from next launch is in
    // STORAGE order, never apply order, and enforcement has to predict that
    // same array, not the plan's approval sequence.
    //
    // Verified against `buildExactTriggerIndex` and `correct()` directly before
    // trusting this expectation, not derived by re-reasoning about passes.
    //
    // Seeded First, then Second — storage order First/Second. The plan
    // replaces them in the OPPOSITE order (Second's replacement given first),
    // so this also proves apply order is not silently equivalent to storage
    // order for a two-word plan.
    let (manager, _) = makeManager()
    var live = try seed(
      manager,
      [CustomWord(canonical: "First"), CustomWord(canonical: "Second")])
    let first = try #require(live.first { $0.canonical == "First" })
    let second = try #require(live.first { $0.canonical == "Second" })

    let receipt = try manager.commitImport(
      plan(
        baseline: live,
        additions: [candidate("Zed", aliases: .supplied(["Claude Code"]))],
        replacements: [
          CustomWordsImportReplacement(existingID: second.id, candidate: candidate("Claude Code")),
          CustomWordsImportReplacement(existingID: first.id, candidate: candidate("claudecode")),
        ]),
      to: &live)

    // Second occupies the LATER storage slot, so it owns the compound key —
    // regardless of being resolved FIRST in the plan. It already spells
    // "Claude Code" exactly, so it declines to intercept and the alias is kept.
    let added = try #require(live.first { $0.canonical == "Zed" })
    #expect(
      added.aliases == ["Claude Code"],
      "apply order would have wrongly dropped this alias")
    #expect(receipt.droppedAliasCollisions.isEmpty)
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
    let earlier = try #require(live.first { $0.canonical == "Earlier" })

    let receipt = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Zed", aliases: .supplied(["Annie"]))]),
      to: &live)

    // Corrected in #1667. This expected the LATER word, reasoning that aliases
    // are assigned unconditionally so the last writer wins. That reads one
    // surface and stops. The compound pass runs FIRST and takes single tokens,
    // and aliases are FIRST-wins there — so the earlier word intercepts before
    // the alias map is consulted.
    //
    // Verified against the real corrector, which turns "Annie" into "Earlier"
    // for exactly this pair. Naming Later told the user a word that never
    // touches their text holds the alias.
    #expect(receipt.droppedAliasCollisions.map(\.heldBy) == [earlier.id])
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

  @Test("replacing an existing built-in override that moves the canonical retires the built-in")
  func replacingAnExistingOverrideThatRenamesRetiresTheBuiltin() throws {
    let (manager, _) = makeManager()
    var live = try #require(manager.load())
    let builtin = try #require(live.first)
    let originalCount = live.count

    // Edit the built-in WITHOUT renaming it. `update` stores a user override
    // in `file.words` and no tombstone, because the unchanged canonical still
    // hides the built-in — so the list stays the same size.
    var edited = builtin
    edited.aliases = builtin.aliases + ["extra alias"]
    try manager.update(word: edited, in: &live)
    let reloaded = try #require(manager.load())
    #expect(reloaded.count == originalCount)

    // Now a reviewed Replace moves the canonical away. The override already
    // lives in `file.words`, so this takes the indexed branch rather than the
    // create-an-override branch — the built-in must still be retired.
    var working = reloaded
    let existing = try #require(reloaded.first { $0.id == builtin.id })
    _ = try manager.commitImport(
      plan(
        baseline: reloaded,
        replacements: [
          CustomWordsImportReplacement(
            existingID: existing.id,
            candidate: candidate("\(builtin.canonical) Renamed"))
        ]),
      to: &working)

    #expect(working.count == originalCount)
    #expect(working.contains { $0.canonical == "\(builtin.canonical) Renamed" })
    #expect(working.contains { $0.canonical == builtin.canonical } == false)
  }

  @Test("a replace that keeps the built-in's canonical does not retire the built-in")
  func replacingABuiltinWithoutRenamingLeavesItRestorable() throws {
    let (manager, url) = makeManager()
    var live = try #require(manager.load())
    let builtin = try #require(live.first)
    let originalCount = live.count

    // Same canonical, new aliases: the override keeps hiding the built-in on
    // its own, so recording a tombstone would persist a deletion the user
    // never performed. Retiring is reserved for a canonical that MOVES away,
    // which is the only case where the built-in would otherwise resurface.
    _ = try manager.commitImport(
      plan(
        baseline: live,
        replacements: [
          CustomWordsImportReplacement(
            existingID: builtin.id,
            candidate: candidate(builtin.canonical, aliases: .supplied(["fresh alias"])))
        ]),
      to: &live)

    #expect(live.count == originalCount)

    let file = try #require(
      try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let tombstones = file["deletedBuiltinIds"] as? [String] ?? []
    #expect(tombstones.isEmpty)

    // The override carries the new aliases and is the only word with this
    // canonical — the built-in is hidden, not duplicated and not retired.
    let matching = live.filter { $0.canonical == builtin.canonical }
    #expect(matching.count == 1)
    #expect(matching.first?.aliases.contains("fresh alias") == true)
  }

  @Test(
    "renaming a built-in through update leaves exactly one word, not the built-in plus an override (#1670)"
  )
  func renamingABuiltinThroughUpdateRetiresTheBuiltinInsteadOfDuplicatingIt() throws {
    let (manager, url) = makeManager()
    var live = try #require(manager.load())
    let builtin = try #require(live.first)
    let originalCount = live.count

    var renamed = builtin
    renamed.canonical = "\(builtin.canonical) Renamed"
    try manager.update(word: renamed, in: &live)

    #expect(live.count == originalCount)
    #expect(live.contains { $0.canonical == "\(builtin.canonical) Renamed" })
    #expect(live.contains { $0.canonical == builtin.canonical } == false)

    // Same duplicate-ID hazard `replacingABuiltinRetiresTheBuiltinInsteadOfDuplicatingIt`
    // guards for commitImport: a reload must not resurface the built-in either.
    let reloaded = try #require(manager.load())
    #expect(reloaded.filter { $0.id == builtin.id }.count == 1)

    // `deletedBuiltinIds` stores `BuiltinWord.id` (a stable string like
    // "enviouswispr"), not the `CustomWord.id` UUID shown above — look up the
    // matching entry by canonical to get the right key to check.
    let matchingBuiltin = try #require(
      CustomWordsManager.builtinDefaults.first {
        $0.word.canonical.lowercased() == builtin.canonical.lowercased()
      })
    let file = try #require(
      try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let tombstones = file["deletedBuiltinIds"] as? [String] ?? []
    #expect(tombstones.contains(matchingBuiltin.id))
  }

  @Test("renaming a built-in then renaming it back leaves exactly one word (#1670 DoD)")
  func renamingABuiltinThenRestoringItsOriginalNameLeavesExactlyOneWord() throws {
    let (manager, _) = makeManager()
    var live = try #require(manager.load())
    let builtin = try #require(live.first)
    let originalCount = live.count
    let originalCanonical = builtin.canonical

    var renamed = builtin
    renamed.canonical = "\(originalCanonical) Renamed"
    try manager.update(word: renamed, in: &live)

    // Rename back to the built-in's original text. The built-in stays
    // tombstoned (the identity is now this user override, not a restored
    // built-in) — the DoD asks only that this behave sanely, i.e. exactly
    // one word, never the duplicate-ID hazard the forward rename used to hit.
    var restored = renamed
    restored.canonical = originalCanonical
    try manager.update(word: restored, in: &live)

    #expect(live.count == originalCount)
    let matching = live.filter { $0.canonical == originalCanonical }
    #expect(matching.count == 1)

    let reloaded = try #require(manager.load())
    #expect(reloaded.filter { $0.id == builtin.id }.count == 1)
  }

  @Test(
    "renaming a built-in's aliases through update, without moving its canonical, does not tombstone it (#1670)"
  )
  func updateWithoutRenamingLeavesTheBuiltinRestorable() throws {
    let (manager, url) = makeManager()
    var live = try #require(manager.load())
    let builtin = try #require(live.first)
    let originalCount = live.count

    // Same canonical, new aliases: the override keeps hiding the built-in on
    // its own, so recording a tombstone would persist a deletion the user
    // never performed (mirrors replacingABuiltinWithoutRenamingLeavesItRestorable).
    var edited = builtin
    edited.aliases = builtin.aliases + ["extra alias"]
    try manager.update(word: edited, in: &live)

    #expect(live.count == originalCount)

    let file = try #require(
      try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let tombstones = file["deletedBuiltinIds"] as? [String] ?? []
    #expect(tombstones.isEmpty)

    let matching = live.filter { $0.canonical == builtin.canonical }
    #expect(matching.count == 1)
    #expect(matching.first?.aliases.contains("extra alias") == true)
  }

  @Test("an import survives a library where a duplicate ID was constructed directly")
  func importSurvivesADirectlyConstructedDuplicateID() throws {
    let (manager, url) = makeManager()
    let live = try #require(manager.load())
    let builtin = try #require(live.first)

    // #1670 (fixed): renaming a built-in through `update` used to leave a
    // user override carrying the built-in's OWN UUID while `mergedWords`
    // kept showing the (no-longer-tombstoned) built-in too, so the two
    // shared an id. That path is fixed now — `update` tombstones the
    // built-in when the canonical moves away, so it can no longer produce
    // this duplicate. `commitImport`'s defensive handling of a non-unique
    // list is still worth proving, so construct the duplicate directly by
    // writing it to disk rather than relying on a (fixed) bug to produce it.
    struct RawFile: Codable {
      var version = 1
      var builtinsVersion = 1
      var deletedBuiltinIds: [String] = []
      var words: [CustomWord] = []
    }
    var renamed = builtin
    renamed.canonical = "\(builtin.canonical) Renamed"
    try JSONEncoder().encode(RawFile(words: [renamed])).write(to: url, options: [.atomic])

    let reloaded = try #require(manager.load())
    #expect(reloaded.filter { $0.id == builtin.id }.count == 2)

    var working = reloaded
    let receipt = try manager.commitImport(
      plan(baseline: reloaded, additions: [candidate("Kubernetes")]), to: &working)

    #expect(receipt.addedIDs.count == 1)
    #expect(working.contains { $0.canonical == "Kubernetes" })
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
