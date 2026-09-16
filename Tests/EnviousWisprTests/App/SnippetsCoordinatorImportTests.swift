import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPostProcessing

/// #2997 — what the coordinator publishes after an import, and how it reports the store.
///
/// `.productOutcome`: when this fails the settings list and the dictation drivers disagree
/// about which snippets exist, an edit made during an import is silently undone, every
/// snippet is switched off for the session, or a stale review is shown as a failure.
@MainActor
@Suite("Snippets coordinator import (#2997)", .tags(.productOutcome))
struct SnippetsCoordinatorImportTests {

  private func makeCoordinator() -> (SnippetsCoordinator, SnippetsManager) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-snippets-coordinator-\(UUID().uuidString)", isDirectory: true)
    let manager = SnippetsManager(fileURL: dir.appendingPathComponent("snippets.json"))
    // A first launch seeds starter snippets; the tests want a known list, so clear them.
    let coordinator = SnippetsCoordinator(manager: manager)
    for starter in coordinator.snippets { coordinator.delete(starter) }
    return (coordinator, manager)
  }

  /// A complete file from a NEWER app: the store reads it as unreadable (unknown data that
  /// must not be overwritten), which is the case these tests stage. A truncated document
  /// would instead be archived as corrupt and read as empty.
  private static let newerVersionFile = Data(
    "{\"version\": 99, \"keyword\": \"backslash\", \"snippets\": []}".utf8)

  /// Stages the unreadable re-read and PROVES it: a fixture write that failed would leave a
  /// readable file, and the test would then pass through the branch it is not about.
  private static func makeUnreadable(_ manager: SnippetsManager) {
    do {
      try newerVersionFile.write(to: manager.storageURL)
    } catch {
      Issue.record("could not stage the unreadable file: \(error)")
    }
    #expect(manager.loadedVocabulary() == nil, "the staged file must read as unreadable")
  }

  private func plan(
    _ coordinator: SnippetsCoordinator, additions: [Snippet]
  ) -> SnippetsCoordinator.SnippetImportCommitPlan {
    SnippetsCoordinator.SnippetImportCommitPlan(
      baseline: coordinator.snippets, additions: additions)
  }

  @Test("A committed import is published once, to the list and to the drivers")
  func commitPublishes() async throws {
    let (coordinator, _) = makeCoordinator()
    let existing = Snippet(trigger: "my email", expansion: "sam@example.com")
    #expect(coordinator.save(existing))
    var published: [SnippetVocabulary] = []
    coordinator.onVocabularyChanged = { published.append($0) }
    let addition = Snippet(trigger: "sig", expansion: "Best,\nSam")

    let outcome = await coordinator.commitImport(plan(coordinator, additions: [addition]))

    guard case .committed(let receipt) = outcome else {
      Issue.record("expected .committed, got \(outcome)")
      return
    }
    #expect(receipt.addedIDs == [addition.id])
    #expect(coordinator.snippets.map(\.id) == [addition.id, existing.id])
    #expect(published.count == 1)
    #expect(published.first?.snippets.map(\.id) == [addition.id, existing.id])
    #expect(coordinator.errorMessage == nil)
  }

  @Test("An empty plan publishes nothing and touches no file")
  func emptyPlanPublishesNothing() async throws {
    let (coordinator, manager) = makeCoordinator()
    let before = manager.load()
    var published = 0
    coordinator.onVocabularyChanged = { _ in published += 1 }

    let outcome = await coordinator.commitImport(plan(coordinator, additions: []))

    guard case .committed(let receipt) = outcome else {
      Issue.record("expected .committed, got \(outcome)")
      return
    }
    #expect(receipt.addedIDs.isEmpty)
    #expect(published == 0)
    #expect(manager.load().generation == before.generation)
  }

  @Test("What is published is the DISK state: an edit saved after the store write wins")
  func publishesDiskStateNotTheReceipt() async throws {
    let (coordinator, _) = makeCoordinator()
    let addition = Snippet(trigger: "sig", expansion: "hi")
    let lateEdit = Snippet(trigger: "late", expansion: "saved during the import")
    // The window between the store write returning and the main actor publishing.
    coordinator.importWriteDidReturn = { #expect(coordinator.save(lateEdit)) }

    let outcome = await coordinator.commitImport(plan(coordinator, additions: [addition]))

    guard case .committed(let receipt) = outcome else {
      Issue.record("expected .committed, got \(outcome)")
      return
    }
    // The receipt predates the edit; the published list carries both.
    #expect(receipt.vocabulary.snippets.map(\.id) == [addition.id])
    #expect(Set(coordinator.snippets.map(\.id)) == [lateEdit.id, addition.id])
    #expect(coordinator.vocabulary.generation > receipt.vocabulary.generation)
  }

  @Test("If the re-read fails, a newer published list is kept and an older one is replaced by the receipt; never empty")
  func unreadableRereadFallsBackOnGenerations() async throws {
    // Case 1: nothing newer was published, so the receipt is adopted.
    do {
      let (coordinator, manager) = makeCoordinator()
      let addition = Snippet(trigger: "sig", expansion: "hi")
      coordinator.importWriteDidReturn = {
        Self.makeUnreadable(manager)
      }
      let outcome = await coordinator.commitImport(plan(coordinator, additions: [addition]))
      guard case .committed(let receipt) = outcome else {
        Issue.record("expected .committed, got \(outcome)")
        return
      }
      #expect(coordinator.vocabulary == receipt.vocabulary)
      #expect(coordinator.snippets.map(\.id) == [addition.id])
    }
    // Case 2: an edit was published after the write, so it is kept over the older receipt.
    do {
      let (coordinator, manager) = makeCoordinator()
      let addition = Snippet(trigger: "sig", expansion: "hi")
      let lateEdit = Snippet(trigger: "late", expansion: "newer")
      coordinator.importWriteDidReturn = {
        #expect(coordinator.save(lateEdit))
        Self.makeUnreadable(manager)
      }
      let generationBefore = coordinator.vocabulary.generation
      let outcome = await coordinator.commitImport(plan(coordinator, additions: [addition]))
      guard case .committed(let receipt) = outcome else {
        Issue.record("expected .committed, got \(outcome)")
        return
      }
      #expect(coordinator.vocabulary.generation > receipt.vocabulary.generation)
      #expect(coordinator.vocabulary.generation > generationBefore)
      #expect(Set(coordinator.snippets.map(\.id)) == [lateEdit.id, addition.id])
      #expect(!coordinator.snippets.isEmpty)
    }
  }

  @Test("A list changed during review is reported as stale, not as a failure, and writes nothing")
  func staleIsAnOutcome() async throws {
    let (coordinator, manager) = makeCoordinator()
    let reviewedAgainst = coordinator.snippets
    // Another EnviousWispr process saves after the review was built.
    let other = SnippetsManager(fileURL: manager.storageURL)
    try other.upsert(Snippet(trigger: "elsewhere", expansion: "x"))
    var published = 0
    coordinator.onVocabularyChanged = { _ in published += 1 }

    let outcome = await coordinator.commitImport(
      SnippetsCoordinator.SnippetImportCommitPlan(
        baseline: reviewedAgainst, additions: [Snippet(trigger: "sig", expansion: "hi")]))

    #expect(outcome == .stale)
    #expect(published == 0)
    #expect(coordinator.errorMessage == nil)
    #expect(manager.load().snippets.map(\.trigger) == ["elsewhere"])
  }

  @Test("Validation and store failures carry the coordinator's own sentences and never the page's error slot")
  func failuresAreMappedToSentences() async throws {
    let (coordinator, manager) = makeCoordinator()
    #expect(coordinator.save(Snippet(trigger: "my email", expansion: "sam@example.com")))

    let duplicate = await coordinator.commitImport(
      plan(coordinator, additions: [Snippet(trigger: "MY EMAIL", expansion: "other")]))
    #expect(
      duplicate
        == .failed(
          message: SnippetsCoordinator.message(
            for: SnippetValidationError.duplicateTrigger(existing: "my email"))))

    let baseline = coordinator.snippets
    try Self.newerVersionFile.write(to: manager.storageURL)
    let unreadable = await coordinator.commitImport(
      SnippetsCoordinator.SnippetImportCommitPlan(
        baseline: baseline, additions: [Snippet(trigger: "sig", expansion: "hi")]))
    #expect(
      unreadable
        == .failed(
          message: SnippetsCoordinator.message(for: SnippetStoreError.existingFileUnreadable)))
    #expect(coordinator.errorMessage == nil)
  }

  @Test("Every store error has a sentence, including the stale one")
  func staleErrorHasASentence() {
    let sentence = SnippetsCoordinator.message(for: SnippetStoreError.listChangedDuringReview)
    #expect(sentence.contains("changed while you were reviewing"))
    #expect(sentence.contains("Nothing was imported"))
  }
}
