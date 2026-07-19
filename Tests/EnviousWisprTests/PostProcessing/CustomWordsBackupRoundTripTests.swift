import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #1680 (PR-E1) — export → compare → commit, against real files.
///
/// The plan parks the full round trip in PR-U1, because U1 is what reads a
/// backup off disk through a file picker. That deferral would leave export's
/// central promise — "this file can be restored" — untested in the PR that
/// makes the promise, so the contract-level round trip runs here now and U1
/// adds the picker leg on top.
@MainActor
@Suite("CustomWordsBackupRoundTrip")
struct CustomWordsBackupRoundTripTests {

  private func makeManager() -> (CustomWordsManager, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-roundtrip-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("custom-words.json")
    return (CustomWordsManager(fileURL: url), url)
  }

  @Test("a user's own words survive export and restore onto a fresh library")
  func exportThenRestoreRebuildsEveryUserAuthoredWord() async throws {
    // Mac A: two authored words, one carrying full configuration.
    let (source, _) = makeManager()
    var live = source.load() ?? []
    try source.add(word: CustomWord(canonical: "Qualtrics", aliases: ["qualtrix"]), to: &live)
    try source.add(
      word: CustomWord(
        canonical: "Kubernetes", aliases: ["k8s"], category: .brand, priority: 4,
        forceReplace: true, caseSensitive: true, minSimilarityOverride: 0.75),
      to: &live)

    let exported = live.filter { $0.source == .user }
    #expect(exported.count == 2, "built-ins must not be in the export set")
    let backup = try CustomWordsTransferDocument(
      data: CustomWordsTransferDocument(words: exported).encoded())

    // Mac B: a fresh library. Never actually empty — the built-ins are merged
    // into every effective list — so "everything classifies as new" only holds
    // for words that don't collide with a built-in.
    let (destination, _) = makeManager()
    var fresh = try #require(destination.load())
    // A fresh library is never empty: `mergedWords` folds the built-ins into
    // every effective list. Only the user-authored subset is empty.
    #expect(fresh.contains { $0.source == .user } == false)
    #expect(fresh.isEmpty == false)

    let candidates = try backup.candidatesForImport()
    let comparisons = try await CustomWordsImportCompareEngine().compare(
      candidates: candidates,
      against: fresh,
      fuzzyPolicy: .disabled
    )
    #expect(comparisons.allSatisfy { $0.classification == .new })

    let receipt = try destination.commitImport(
      CustomWordsImportCommitPlan(
        baseline: CustomWordsImportLibrarySnapshot(words: fresh),
        additions: comparisons.map(\.candidate),
        replacements: []),
      to: &fresh)
    #expect(receipt.addedIDs.count == 2)

    // Compare what the user actually authored, field by field.
    let restored = Dictionary(
      uniqueKeysWithValues: fresh.filter { $0.source == .user }.map { ($0.canonical, $0) })
    let kubernetes = try #require(restored["Kubernetes"])
    #expect(kubernetes.aliases == ["k8s"])
    #expect(kubernetes.category == .brand)
    #expect(kubernetes.priority == 4)
    #expect(kubernetes.forceReplace == true)
    #expect(kubernetes.caseSensitive == true)
    #expect(kubernetes.minSimilarityOverride == 0.75)
    #expect(try #require(restored["Qualtrics"]).aliases == ["qualtrix"])

    // Usage history is local to the Mac that earned it.
    #expect(kubernetes.frequencyUsed == 0)
    #expect(kubernetes.lastUsed == nil)

    // A restored word is a local word with a local identity.
    let foreignIDs = Set(backup.words.map(\.id))
    #expect(fresh.filter { $0.source == .user }.allSatisfy { !foreignIDs.contains($0.id) })
  }

  @Test("an edited built-in exports, and restoring it needs a replacement")
  func restoringABuiltinOverrideRequiresAReplacementNotAnAdd() async throws {
    // Mac A edits a built-in. The override is a real user word and must export.
    let (source, _) = makeManager()
    var live = try #require(source.load())
    let github = try #require(live.first { $0.canonical == "GitHub" })
    #expect(github.source == .builtin)
    var edited = github
    edited.aliases = ["git hub", "gh"]
    try source.update(word: edited, in: &live)

    let exported = live.filter { $0.source == .user }
    #expect(
      exported.contains { $0.canonical == "GitHub" },
      "the override must export immediately, without waiting for a relaunch")

    // Mac B still has the untouched built-in, so the incoming word is not new.
    let (destination, _) = makeManager()
    var fresh = try #require(destination.load())
    let backup = CustomWordsTransferDocument(words: exported)
    let comparisons = try await CustomWordsImportCompareEngine().compare(
      candidates: backup.candidatesForImport(),
      against: fresh,
      fuzzyPolicy: .disabled
    )
    let row = try #require(comparisons.first { $0.candidate.canonical == "GitHub" })
    guard case .exact(let existing) = row.classification else {
      Issue.record("expected the override to match Mac B's built-in exactly")
      return
    }

    // The machinery restores it — but only through a REPLACEMENT. The v1
    // review screen offers Add or Skip only, so this row would be Skip-only
    // and the user's edit would not come back. That gap is the reason backup
    // restore is the first real consumer of the alias-merge offer (#1619), and
    // PR-U1 must surface it rather than silently skipping.
    let receipt = try destination.commitImport(
      CustomWordsImportCommitPlan(
        baseline: CustomWordsImportLibrarySnapshot(words: fresh),
        additions: [],
        replacements: [
          CustomWordsImportReplacement(existingID: existing.id, candidate: row.candidate)
        ]),
      to: &fresh)

    #expect(receipt.replacedIDs.count == 1)
    let restored = try #require(fresh.first { $0.canonical == "GitHub" })
    #expect(restored.aliases == ["git hub", "gh"])
    #expect(restored.source == .user)
  }

  @Test("deleted built-ins are not carried by a backup, by design")
  func deletedBuiltinTombstonesAreANonGoal() throws {
    let (source, _) = makeManager()
    var live = try #require(source.load())
    let claude = try #require(live.first { $0.canonical == "Claude" })
    try source.remove(id: claude.id, from: &live)
    #expect(live.contains { $0.canonical == "Claude" } == false)

    let exported = live.filter { $0.source == .user }
    let json = try #require(
      String(data: try CustomWordsTransferDocument(words: exported).encoded(), encoding: .utf8))

    // Frozen as a decision, not left to look like a bug: restoring your words
    // onto a fresh Mac leaves that Mac's built-ins active, because the review
    // model has no delete operation and a backup whose restore path cannot
    // express part of its content would be a broken promise.
    #expect(!json.contains("deletedBuiltinIds"))
    #expect(!json.contains("Claude"))
  }
}
