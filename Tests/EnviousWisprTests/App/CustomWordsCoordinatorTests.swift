import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPostProcessing

/// #1701 Chunk 2 — the AppKit adapter's own observability contract for
/// bulk-import enrichment: `pendingEnrichmentBatchTotal` round-tripping and
/// `onImportCommitted`'s firing rule. Persistence correctness itself is owned
/// by `CustomWordsBulkEnrichmentTests` (manager-level); this suite is about
/// what the coordinator surfaces to its observers.
@MainActor
@Suite("CustomWordsCoordinator — bulk-import enrichment observability")
struct CustomWordsCoordinatorTests {

  private func makeCoordinator() -> (CustomWordsCoordinator, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-coordinator-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("custom-words.json")
    return (CustomWordsCoordinator(manager: CustomWordsManager(fileURL: url)), url)
  }

  private func plan(
    baseline: [CustomWord], additions: [CustomWordsImportCandidate] = []
  ) -> CustomWordsImportCommitPlan {
    CustomWordsImportCommitPlan(
      baseline: CustomWordsImportLibrarySnapshot(words: baseline), additions: additions,
      replacements: [])
  }

  @Test("pendingEnrichmentBatchTotal round-trips through loadSnapshot()")
  func pendingTotalRoundTripsThroughLoadSnapshot() {
    let (first, url) = makeCoordinator()
    #expect(first.pendingEnrichmentBatchTotal == nil, "a fresh library has no run in progress")

    _ = first.commitImport(
      plan(
        baseline: first.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))
    #expect(first.pendingEnrichmentBatchTotal == 1)

    // A SECOND coordinator instance backed by the SAME file (a fresh
    // `loadSnapshot()` call, not the same in-memory object) must observe the
    // same total — proving the value round-trips through disk, not just a
    // held reference.
    let second = CustomWordsCoordinator(manager: CustomWordsManager(fileURL: url))
    #expect(second.pendingEnrichmentBatchTotal == 1)
  }

  @Test("onImportCommitted fires on a nonempty commit")
  func onImportCommittedFiresOnNonemptyCommit() {
    let (coordinator, _) = makeCoordinator()
    var fired = 0
    coordinator.onImportCommitted = { fired += 1 }

    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))

    #expect(fired == 1)
  }

  @Test("onImportCommitted does not fire on an all-Skip commit")
  func onImportCommittedDoesNotFireOnEmptyCommit() {
    let (coordinator, _) = makeCoordinator()
    var fired = 0
    coordinator.onImportCommitted = { fired += 1 }

    _ = coordinator.commitImport(plan(baseline: coordinator.customWords))

    #expect(fired == 0)
  }

  @Test("onImportCommitted does not fire on a stale or failed commit")
  func onImportCommittedDoesNotFireOnStaleCommit() {
    let (coordinator, _) = makeCoordinator()
    let staleBaseline = coordinator.customWords
    // Change the library after the (stale) baseline was captured.
    _ = coordinator.add(CustomWord(canonical: "Interloper"))

    var fired = 0
    coordinator.onImportCommitted = { fired += 1 }

    let outcome = coordinator.commitImport(
      plan(
        baseline: staleBaseline, additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))

    guard case .stale = outcome else {
      Issue.record("expected a stale outcome")
      return
    }
    #expect(fired == 0)
  }

  @Test("a stale-commit refresh adopts words AND the durable total together, from one snapshot")
  func staleCommitRefreshAdoptsWordsAndTotalTogether() {
    // Codex Chunk 2 review round 2 finding 4: `refreshFromDiskIfPossible`
    // used to call `manager.load()` (words only), so a stale-commit refresh
    // after another app instance wrote could adopt fresh words paired with a
    // now-stale (or missing) total — breaking the atomic-pair guarantee
    // every other read/write path in this coordinator already honors.
    let (coordinator, url) = makeCoordinator()
    let staleBaseline = coordinator.customWords

    // A SEPARATE manager instance (a second running app copy, #1747) commits
    // an eligible import directly to the same file, bypassing this
    // coordinator entirely — both new words AND a fresh durable total.
    let rawManager = CustomWordsManager(fileURL: url)
    var rawWords = rawManager.load() ?? []
    _ = try! rawManager.commitImport(
      plan(
        baseline: rawWords,
        additions: [
          CustomWordsImportCandidate(canonical: "Kubernetes"),
          CustomWordsImportCandidate(canonical: "Qualtrics"),
        ]),
      to: &rawWords)

    // This coordinator's own commit, built against the now-stale baseline,
    // triggers the internal refresh.
    let outcome = coordinator.commitImport(
      plan(baseline: staleBaseline, additions: [CustomWordsImportCandidate(canonical: "Anthropic")])
    )
    guard case .stale = outcome else {
      Issue.record("expected a stale outcome")
      return
    }

    #expect(coordinator.customWords.contains { $0.canonical == "Kubernetes" })
    #expect(coordinator.customWords.contains { $0.canonical == "Qualtrics" })
    #expect(
      coordinator.pendingEnrichmentBatchTotal == 2,
      "the total must reflect the SAME snapshot the refreshed words came from, never left stale")
  }

  @Test("a total-only refresh never republishes unchanged words to pipelines")
  func totalOnlyRefreshDoesNotFireOnWordsChanged() throws {
    // Codex Chunk 2 review round 3 finding 3a: the old unconditional
    // `onWordsChanged?(customWords)` fired even when only the total changed,
    // needlessly republishing byte-identical words to every pipeline
    // consumer.
    let (coordinator, url) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))
    let wordsBefore = coordinator.customWords

    // Directly edit the total on disk, leaving `words` byte-identical — a
    // scenario real commits/checkpoints don't produce on their own, but
    // isolates this specific invariant precisely.
    let raw = try Data(contentsOf: url)
    var json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
    json["pendingEnrichmentBatchTotal"] = 5
    try JSONSerialization.data(withJSONObject: json).write(to: url, options: [.atomic])

    var changedFired = 0
    coordinator.onWordsChanged = { _ in changedFired += 1 }

    #expect(coordinator.refreshFromDiskIfPossible() == true)

    #expect(coordinator.pendingEnrichmentBatchTotal == 5)
    #expect(coordinator.customWords == wordsBefore)
    #expect(changedFired == 0, "words never changed, so onWordsChanged must never fire")
  }

  @Test("a cross-process transition to a new run clears a stale display from a previous one")
  func crossProcessNewRunClearsStaleDisplay() throws {
    // Codex Chunk 2 review round 3 finding 3b: the local `commitImport` path
    // already clears `mostRecentEnrichment` on a nil -> non-nil transition;
    // `refreshFromDiskIfPossible` must apply the same rule, or a stale
    // display from THIS coordinator's own already-completed run can flash
    // before another instance's freshly-started run produces its own result.
    let (coordinator, url) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))
    let target = try #require(coordinator.customWords.first { $0.canonical == "Kubernetes" })
    _ = coordinator.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: target.id, generatedAliases: ["k8s"])
    ])
    #expect(coordinator.mostRecentEnrichment != nil, "the completed run left a display behind")
    #expect(coordinator.pendingEnrichmentBatchTotal == nil)

    // A SEPARATE manager instance starts a genuinely NEW run on the same file.
    let rawManager = CustomWordsManager(fileURL: url)
    var rawWords = rawManager.load() ?? []
    _ = try rawManager.commitImport(
      plan(baseline: rawWords, additions: [CustomWordsImportCandidate(canonical: "Qualtrics")]),
      to: &rawWords)

    #expect(coordinator.refreshFromDiskIfPossible() == true)

    #expect(coordinator.pendingEnrichmentBatchTotal == 1)
    #expect(
      coordinator.mostRecentEnrichment == nil,
      "the previous run's display must not survive into the new one")
  }

  // MARK: - pendingEnrichmentCount (Codex Chunk 2 review finding 5 — the UI
  // progress projection: observable, in-memory, safe to read from a SwiftUI
  // `body`, never a proxy for the durable total's mere presence)

  @Test("pendingEnrichmentCount is 0 for a fresh library")
  func pendingEnrichmentCountIsZeroForFreshLibrary() {
    let (coordinator, _) = makeCoordinator()
    #expect(coordinator.pendingEnrichmentCount == 0)
  }

  @Test("pendingEnrichmentCount reflects a commit immediately, in memory")
  func pendingEnrichmentCountReflectsCommit() {
    let (coordinator, _) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [
          CustomWordsImportCandidate(canonical: "Kubernetes"),
          CustomWordsImportCandidate(canonical: "Qualtrics"),
        ]))
    #expect(coordinator.pendingEnrichmentCount == 2)
  }

  @Test("pendingEnrichmentCount drops as checkpoints land and reaches 0 on completion")
  func pendingEnrichmentCountDropsAsCheckpointsLand() {
    let (coordinator, _) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [
          CustomWordsImportCandidate(canonical: "Kubernetes"),
          CustomWordsImportCandidate(canonical: "Qualtrics"),
        ]))
    let words = coordinator.customWords.filter {
      $0.canonical == "Kubernetes" || $0.canonical == "Qualtrics"
    }

    _ = coordinator.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: words[0].id, generatedAliases: [])
    ])
    #expect(coordinator.pendingEnrichmentCount == 1)

    _ = coordinator.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: words[1].id, generatedAliases: [])
    ])
    #expect(coordinator.pendingEnrichmentCount == 0)
  }

  @Test("pendingEnrichmentCount drops to 0 on Cancel")
  func pendingEnrichmentCountDropsToZeroOnCancel() {
    let (coordinator, _) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))
    #expect(coordinator.pendingEnrichmentCount == 1)

    _ = coordinator.cancelEnrichment()
    #expect(coordinator.pendingEnrichmentCount == 0)
  }
}
