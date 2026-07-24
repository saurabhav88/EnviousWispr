import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #1701 Chunk 2 — bulk-import-enrichment persistence: `commitImport`'s
/// pending-flag/total bookkeeping, the repair self-heal, and the two
/// checkpoint transactions (`applyEnrichmentResults` / `cancelEnrichment`).
/// Every test drives a real manager against a temp file, matching
/// `CustomWordsImportCommitTests`'s harness shape.
@MainActor
@Suite("CustomWordsManager — bulk-import enrichment")
struct CustomWordsBulkEnrichmentTests {

  // MARK: - Harness

  private func makeManager() -> (CustomWordsManager, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-bulk-enrichment-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("custom-words.json")
    return (CustomWordsManager(fileURL: url), url)
  }

  private func candidate(_ canonical: String) -> CustomWordsImportCandidate {
    CustomWordsImportCandidate(canonical: canonical)
  }

  /// Seeds words directly (never through the import pipeline), matching
  /// `CustomWordsImportCommitTests`'s harness shape.
  private func seed(
    _ manager: CustomWordsManager, _ words: [CustomWord]
  ) throws -> [CustomWord] {
    var live = manager.load() ?? []
    _ = try manager.addBatch(words, to: &live)
    return live
  }

  private func plan(
    baseline: [CustomWord],
    additions: [CustomWordsImportCandidate] = [],
    replacements: [CustomWordsImportReplacement] = [],
    enrichmentEligible: Bool = true
  ) -> CustomWordsImportCommitPlan {
    CustomWordsImportCommitPlan(
      baseline: CustomWordsImportLibrarySnapshot(words: baseline),
      additions: additions, replacements: replacements,
      enrichmentEligible: enrichmentEligible)
  }

  // MARK: - commitImport: pending flags + total

  @Test("an eligible addition is marked pending and sets the total")
  func eligibleAdditionSetsFlagAndTotal() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    let receipt = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes"), candidate("Qualtrics")]),
      to: &live)

    let added = live.filter { $0.canonical == "Kubernetes" || $0.canonical == "Qualtrics" }
    #expect(added.allSatisfy { $0.enrichmentPending })
    #expect(receipt.pendingEnrichmentBatchTotal == 2)
  }

  @Test("an ineligible-batch addition is never marked pending and sets no total")
  func ineligibleAdditionNeverSetsFlagOrTotal() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    let receipt = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")], enrichmentEligible: false),
      to: &live)

    let added = try #require(live.first { $0.canonical == "Kubernetes" })
    #expect(added.enrichmentPending == false)
    #expect(receipt.pendingEnrichmentBatchTotal == nil)
  }

  @Test("a Replace never enters the enrichment queue, even in an eligible batch")
  func replaceNeverEntersQueue() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Qualtrics")]), to: &live)
    var afterFirstCommit = live
    // Clear the flag as if a drain had already run, isolating this test to
    // the Replace path alone.
    let target = try #require(afterFirstCommit.first { $0.canonical == "Qualtrics" })
    _ = try manager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: target.id, generatedAliases: [])
    ])
    afterFirstCommit = try #require(manager.load())
    live = afterFirstCommit

    let receipt = try manager.commitImport(
      plan(
        baseline: live,
        replacements: [
          CustomWordsImportReplacement(existingID: target.id, candidate: candidate("Qualtrics XM"))
        ]),
      to: &live)

    let replaced = try #require(live.first { $0.id == target.id })
    #expect(replaced.enrichmentPending == false)
    #expect(receipt.pendingEnrichmentBatchTotal == nil)
  }

  @Test("a second import mid-run extends the total, never resets it")
  func secondImportMidRunExtendsTotal() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    let first = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)
    #expect(first.pendingEnrichmentBatchTotal == 1)

    let second = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Qualtrics"), candidate("Anthropic")]),
      to: &live)

    // 1 (still pending from the first commit) + 2 (this commit) = 3, never
    // reset to just this commit's own count.
    #expect(second.pendingEnrichmentBatchTotal == 3)
  }

  @Test("a library with pending words but a nil total repairs once, to the live count")
  func repairHealsANilTotalToTheLivePendingCount() throws {
    let (manager, url) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes"), candidate("Qualtrics")]),
      to: &live)

    // Simulate a library that somehow lost its total (legacy file / partial
    // rollback) while the pending flags themselves survived.
    let raw = try Data(contentsOf: url)
    var json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    json.removeValue(forKey: "pendingEnrichmentBatchTotal")
    try JSONSerialization.data(withJSONObject: json).write(to: url, options: [.atomic])

    let snapshot = try #require(manager.loadSnapshot())
    #expect(snapshot.pendingEnrichmentBatchTotal == nil)

    let repaired = try manager.repairPendingEnrichmentTotalIfNeeded()
    #expect(repaired == 2)

    // Idempotent: repairing again is a no-op that returns the same value.
    let repairedAgain = try manager.repairPendingEnrichmentTotalIfNeeded()
    #expect(repairedAgain == 2)
  }

  @Test("repair heals a total stuck non-nil when nothing is actually pending")
  func repairHealsAStuckNonNilTotalToNil() throws {
    // Codex Chunk 2 review finding 2b's other direction: before the fix,
    // `repairPendingEnrichmentTotalIfNeeded`'s guard only ever fired when
    // `livePendingCount > 0`, so a total stuck non-nil with zero actually
    // pending (e.g. the last pending word was deleted) was never healed.
    let (manager, url) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)
    let target = try #require(live.first { $0.canonical == "Kubernetes" })
    try manager.remove(id: target.id, from: &live)

    // Simulate the total surviving the delete stuck at its pre-delete value
    // (as the pre-fix `applyEnrichmentResults` could leave it).
    let raw = try Data(contentsOf: url)
    var json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    json["pendingEnrichmentBatchTotal"] = 1
    try JSONSerialization.data(withJSONObject: json).write(to: url, options: [.atomic])
    #expect(try #require(manager.loadSnapshot()).pendingEnrichmentBatchTotal == 1)

    let repaired = try manager.repairPendingEnrichmentTotalIfNeeded()
    #expect(repaired == nil)
    #expect(try #require(manager.loadSnapshot()).pendingEnrichmentBatchTotal == nil)
  }

  @Test(
    "committing into an existing-pending-but-nil-total state bases the new total on the live count")
  func commitIntoExistingPendingNilTotalStateBasesTotalOnLiveCount() throws {
    // Codex Chunk 2 review finding 2a: before the fix, committing into this
    // defensive nil-total state wrote a total covering only THIS commit's own
    // new additions — which goes non-nil, so the repair path (only fires when
    // the total IS nil) would never again correct the permanent undercount.
    let (manager, url) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes"), candidate("Qualtrics")]),
      to: &live)

    let raw = try Data(contentsOf: url)
    var json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    json.removeValue(forKey: "pendingEnrichmentBatchTotal")
    try JSONSerialization.data(withJSONObject: json).write(to: url, options: [.atomic])
    live = try #require(manager.load())

    let receipt = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Anthropic")]), to: &live)

    // 2 (already pending, total was nil) + 1 (this commit's own addition) = 3,
    // never just 1 (this commit's own delta alone).
    #expect(receipt.pendingEnrichmentBatchTotal == 3)
  }

  @Test("repair is a no-op when there is nothing pending")
  func repairIsNoOpWithNothingPending() throws {
    let (manager, _) = makeManager()
    let repaired = try manager.repairPendingEnrichmentTotalIfNeeded()
    #expect(repaired == nil)
  }

  // MARK: - applyEnrichmentResults

  @Test("a checkpoint appends to the word's CURRENT aliases, not a stale caller snapshot")
  func checkpointAppendsToCurrentAliasesNotCallerSnapshot() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)
    let target = try #require(live.first { $0.canonical == "Kubernetes" })

    // A concurrent edit lands BETWEEN the model call finishing and the
    // checkpoint arriving — simulated by mutating the word on disk directly,
    // bypassing the caller's in-memory copy entirely.
    var concurrentlyEdited = try #require(manager.load())
    let idx = try #require(concurrentlyEdited.firstIndex { $0.id == target.id })
    concurrentlyEdited[idx].aliases = ["hand-typed-alias"]
    try manager.update(word: concurrentlyEdited[idx], in: &concurrentlyEdited)

    // The checkpoint call still carries the ORIGINAL (now stale) view of the
    // word implicitly — it only ever sends id + generatedAliases, never a
    // snapshot — proving the manager reloads under lock rather than trusting
    // anything the caller might have held.
    let outcome = try manager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: target.id, generatedAliases: ["k8s"])
    ])

    let result = try #require(outcome.snapshot.words.first { $0.id == target.id })
    #expect(result.aliases.contains("hand-typed-alias"), "the concurrent edit must survive")
    #expect(result.aliases.contains("k8s"), "the checkpoint's own alias must also land")
    #expect(result.enrichmentPending == false)
    #expect(outcome.applied.first?.generatedAliases == ["k8s"])
  }

  @Test("applying the same result twice is a no-op the second time")
  func reapplyingTheSameResultIsIdempotent() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)
    let target = try #require(live.first { $0.canonical == "Kubernetes" })

    let result = CustomWordEnrichmentResult(id: target.id, generatedAliases: ["k8s"])
    let first = try manager.applyEnrichmentResults([result])
    #expect(try #require(first.snapshot.words.first { $0.id == target.id }).aliases == ["k8s"])
    #expect(first.applied.first?.generatedAliases == ["k8s"])

    let second = try manager.applyEnrichmentResults([result])
    let word = try #require(second.snapshot.words.first { $0.id == target.id })
    #expect(word.aliases == ["k8s"], "no duplicate alias from reapplying")
    #expect(word.enrichmentPending == false)
    #expect(second.applied.isEmpty, "the second pass applied nothing — already resolved")
  }

  @Test("a deleted word's ID is skipped, never resurrected")
  func deletedIDIsSkippedNotResurrected() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)
    let target = try #require(live.first { $0.canonical == "Kubernetes" })

    try manager.remove(id: target.id, from: &live)
    let countBefore = try #require(manager.load()).count

    let outcome = try manager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: target.id, generatedAliases: ["k8s"])
    ])

    #expect(outcome.snapshot.words.contains { $0.id == target.id } == false)
    #expect(outcome.snapshot.words.count == countBefore)
    #expect(outcome.applied.isEmpty)
  }

  @Test("two processes' results for the same word: first checkpoint wins, the late one no-ops")
  func firstCheckpointWinsOverALateDuplicate() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)
    let target = try #require(live.first { $0.canonical == "Kubernetes" })

    // Two independent "processes" both computed a result for the same word
    // before either checkpointed.
    let processA = CustomWordEnrichmentResult(id: target.id, generatedAliases: ["k8s"])
    let processB = CustomWordEnrichmentResult(id: target.id, generatedAliases: ["kube"])

    _ = try manager.applyEnrichmentResults([processA])
    let afterLate = try manager.applyEnrichmentResults([processB])

    let word = try #require(afterLate.snapshot.words.first { $0.id == target.id })
    #expect(word.aliases == ["k8s"], "the first checkpoint's alias wins")
    #expect(!word.aliases.contains("kube"), "the late duplicate must not also apply")
    #expect(afterLate.applied.isEmpty, "the late duplicate applied nothing")
  }

  @Test("a late checkpoint arriving after Cancel is a no-op, never re-enriching")
  func lateCheckpointAfterCancelIsNoOp() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)
    let target = try #require(live.first { $0.canonical == "Kubernetes" })

    _ = try manager.cancelEnrichment()

    let afterLateCheckpoint = try manager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: target.id, generatedAliases: ["k8s"])
    ])

    let word = try #require(afterLateCheckpoint.snapshot.words.first { $0.id == target.id })
    #expect(word.enrichmentPending == false)
    #expect(word.aliases.isEmpty, "a cancelled word must not be re-enriched by a late result")
    #expect(afterLateCheckpoint.applied.isEmpty)
  }

  @Test("the total clears to nil once the live pending count reaches zero")
  func totalClearsWhenPendingCountReachesZero() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes"), candidate("Qualtrics")]),
      to: &live)
    let words = live.filter { $0.canonical == "Kubernetes" || $0.canonical == "Qualtrics" }

    let afterFirst = try manager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: words[0].id, generatedAliases: [])
    ])
    #expect(afterFirst.snapshot.pendingEnrichmentBatchTotal == 2, "one word still pending")

    let afterSecond = try manager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: words[1].id, generatedAliases: [])
    ])
    #expect(afterSecond.snapshot.pendingEnrichmentBatchTotal == nil, "nothing left pending")
  }

  @Test("the total clears even when the batch's only result was a deleted word")
  func totalClearsWhenTheOnlyResultReferencesADeletedWord() throws {
    // Codex Chunk 2 review finding 2b: clearing used to be gated behind
    // `changed`, so a checkpoint whose only result referenced an
    // already-deleted word (contributing nothing itself) never reached the
    // total-clearing check, even though the delete had already brought the
    // live pending count to zero.
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)
    let target = try #require(live.first { $0.canonical == "Kubernetes" })

    try manager.remove(id: target.id, from: &live)

    let outcome = try manager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: target.id, generatedAliases: ["k8s"])
    ])
    #expect(outcome.snapshot.pendingEnrichmentBatchTotal == nil)
  }

  // MARK: - applyEnrichmentResults: alias-ownership authority (Codex Chunk 2
  // review finding 3 — generated aliases must clear the SAME authority the
  // import commit path already uses, never a second, weaker in-word-only check)

  @Test("a generated alias colliding with another word's canonical is dropped, never persisted")
  func generatedAliasCollidingWithAnotherCanonicalIsDropped() throws {
    let (manager, _) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Kubernetes")])
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Qualtrics")]), to: &live)
    let target = try #require(live.first { $0.canonical == "Qualtrics" })

    let outcome = try manager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: target.id, generatedAliases: ["kubernetes", "qualtrix"])
    ])

    let word = try #require(outcome.snapshot.words.first { $0.id == target.id })
    #expect(word.aliases == ["qualtrix"], "the colliding generated alias must not persist")
    #expect(outcome.applied.first?.generatedAliases == ["qualtrix"])
  }

  @Test("a generated alias colliding with an incumbent's human-authored alias is dropped (D17)")
  func generatedAliasCollidingWithHumanAuthoredAliasIsDropped() throws {
    let (manager, _) = makeManager()
    var live = try seed(manager, [CustomWord(canonical: "Anika", aliases: ["annie"])])
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Annabelle")]), to: &live)
    let target = try #require(live.first { $0.canonical == "Annabelle" })

    let outcome = try manager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: target.id, generatedAliases: ["Annie", "belle"])
    ])

    let word = try #require(outcome.snapshot.words.first { $0.id == target.id })
    #expect(word.aliases == ["belle"], "the human-authored incumbent alias must win")
    let incumbent = try #require(outcome.snapshot.words.first { $0.canonical == "Anika" })
    #expect(incumbent.aliases == ["annie"], "the incumbent's own alias is untouched")
  }

  @Test(
    "in the SAME checkpoint, one touched word's PRE-EXISTING alias never loses to another touched word's generated duplicate"
  )
  func sameCheckpointPreExistingAliasNeverLostToASiblingTouchedWordsGeneratedDuplicate() throws {
    // Codex Chunk 2 review round 2 finding 1: reusing `enforceAliases`
    // wholesale re-evaluated EVERY touched word's full alias list — including
    // aliases that were already persisted before this checkpoint and were
    // never part of its generated content — so word B's own pre-existing
    // alias could lose to word A's newly generated duplicate purely because
    // both happened to receive a checkpoint in the same batch. A comes FIRST
    // in this batch specifically to reproduce the touched-order dependency
    // the bug had.
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    // B is pending (enrichment-eligible) AND already carries a supplied
    // alias — a real shape per D17's supersession: an eligible row can
    // already carry a source alias and still be enrichment-eligible.
    let receipt = try manager.commitImport(
      plan(
        baseline: live,
        additions: [
          candidate("Anthropic"),
          CustomWordsImportCandidate(canonical: "Betty", aliases: .supplied(["shared"])),
        ]),
      to: &live)
    #expect(receipt.pendingEnrichmentBatchTotal == 2)
    let wordA = try #require(live.first { $0.canonical == "Anthropic" })
    let wordB = try #require(live.first { $0.canonical == "Betty" })
    #expect(wordB.aliases == ["shared"])

    let outcome = try manager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: wordA.id, generatedAliases: ["shared"]),
      CustomWordEnrichmentResult(id: wordB.id, generatedAliases: ["betty-alt"]),
    ])

    let resultA = try #require(outcome.snapshot.words.first { $0.id == wordA.id })
    let resultB = try #require(outcome.snapshot.words.first { $0.id == wordB.id })
    #expect(resultA.aliases.isEmpty, "A's duplicate must be blocked — B already holds it")
    #expect(
      resultB.aliases == ["shared", "betty-alt"],
      "B's pre-existing alias must survive, AND its own new generated alias must land")
  }

  @Test(
    "a checkpoint with no generated aliases leaves every existing alias byte-for-byte unchanged")
  func emptyResultsLeaveEveryExistingAliasUnchanged() throws {
    let (manager, _) = makeManager()
    var live = try seed(
      manager,
      [
        CustomWord(canonical: "Anika", aliases: ["annie", "annika"]),
        CustomWord(canonical: "Betty", aliases: ["bett", "elizabeth"]),
      ])
    _ = try manager.commitImport(plan(baseline: live, additions: [candidate("Charlie")]), to: &live)
    let target = try #require(live.first { $0.canonical == "Charlie" })
    let before = try #require(manager.load())

    let outcome = try manager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: target.id, generatedAliases: [])
    ])

    for word in before {
      let after = try #require(outcome.snapshot.words.first { $0.id == word.id })
      #expect(
        after.aliases == word.aliases, "\(word.canonical)'s aliases must be byte-for-byte unchanged"
      )
    }
  }

  @Test("a generated alias equal to the word's own canonical is silently dropped, not persisted")
  func generatedAliasEqualToOwnCanonicalIsDropped() throws {
    // Codex Chunk 2 review round 3 finding 1: `resolveAliasOwnership`
    // excludes the target word itself from blocking, so without an explicit
    // own-canonical check (mirroring `enforceAliases`'s own), a generated
    // "Kubernetes" could land as a redundant alias on canonical "Kubernetes".
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)
    let target = try #require(live.first { $0.canonical == "Kubernetes" })

    let outcome = try manager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: target.id, generatedAliases: ["kubernetes", "k8s"])
    ])

    let word = try #require(outcome.snapshot.words.first { $0.id == target.id })
    #expect(word.aliases == ["k8s"], "the self-redundant alias must never persist")
    #expect(outcome.applied.first?.generatedAliases == ["k8s"])
  }

  @Test("a clean generated alias with no collision still lands normally")
  func nonCollidingGeneratedAliasStillLands() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)
    let target = try #require(live.first { $0.canonical == "Kubernetes" })

    let outcome = try manager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: target.id, generatedAliases: ["k8s"])
    ])

    #expect(try #require(outcome.snapshot.words.first { $0.id == target.id }).aliases == ["k8s"])
    #expect(outcome.applied.first?.generatedAliases == ["k8s"])
  }

  // MARK: - cancelEnrichment

  @Test("Cancel sweeps every currently-pending word, not a caller's stale target list")
  func cancelSweepsLiveStateNotAStaleCallerList() throws {
    let (manager, _) = makeManager()
    var live = manager.load() ?? []
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Kubernetes")]), to: &live)

    // A caller whose in-memory idea of the target list is deliberately stale
    // relative to the file: a SECOND import lands, extending the durable
    // queue, without this caller ever observing it.
    _ = try manager.commitImport(
      plan(baseline: live, additions: [candidate("Qualtrics")]), to: &live)

    let snapshot = try manager.cancelEnrichment()

    #expect(snapshot.words.allSatisfy { $0.enrichmentPending == false })
    #expect(snapshot.pendingEnrichmentBatchTotal == nil)
  }

  @Test("Cancel is a safe no-op when nothing is pending")
  func cancelIsNoOpWithNothingPending() throws {
    let (manager, _) = makeManager()
    let snapshot = try manager.cancelEnrichment()
    #expect(snapshot.pendingEnrichmentBatchTotal == nil)
  }
}
