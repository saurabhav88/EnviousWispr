import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPostProcessing

/// Characterizes `CustomWordSuggestionFlow` — the piece of
/// `CustomWordEditSheet`'s Add-term/Edit-word suggestion flow this PR's
/// migration actually touches (#1701 Grounded Review Chunk 1). The founder
/// authorized extracting this piece into a directly testable unit after the
/// reviewer stopped the build for skipping the plan's required Add-term
/// characterization test; the surrounding debounce and loading-indicator
/// choreography stays inline in the view, unchanged, and is covered by
/// Live UAT instead (not unit-testable — no established pattern in this
/// codebase for driving a SwiftUI `.task(id:)` body directly).
///
/// `fetch`'s `suggest` is injected as a plain closure — deterministic, no
/// live FoundationModels call — while the production call site in
/// `CustomWordEditSheet.swift` is what pins the actual `priority: .interactive`
/// argument (grep-verified in the Chunk 1 receipt); the dedicated permit-queue
/// suite (`WordSuggestionServiceTests.swift`) separately proves `.interactive`
/// is served ahead of `.background`.
///
/// `@testable import EnviousWisprPostProcessing` (not a widened public API,
/// Grounded Review Chunk 1 round 2 finding) is what makes `WordSuggestions`'s
/// existing internal memberwise initializer reachable here, matching the
/// established pattern in `ContactsImportCoordinatorTests.swift`.
@MainActor
@Suite("CustomWordSuggestionFlow — Add-term suggestion fetch/apply (#1701 characterization)")
struct CustomWordSuggestionFlowTests {

  @Test("apply: fills suggested aliases and category when both are still empty/general")
  func applyFillsWhenEmpty() {
    let outcome = CustomWordSuggestionFlow.apply(
      suggestions: WordSuggestions(category: .person, suggestedAliases: ["Sourabh", "Sorab"]),
      currentAliases: [],
      currentCategory: .general)
    #expect(outcome.aliases == ["Sourabh", "Sorab"])
    #expect(outcome.category == .person)
    #expect(outcome.suggestionsApplied == true)
    #expect(outcome.noSuggestionsAvailable == false)
  }

  @Test("apply: never overwrites aliases or a category the word already carries")
  func applyNeverOverwritesExisting() {
    let outcome = CustomWordSuggestionFlow.apply(
      suggestions: WordSuggestions(category: .person, suggestedAliases: ["would-overwrite"]),
      currentAliases: ["already-here"],
      currentCategory: .brand)
    // suggestionsApplied still flips true (a suggestion WAS returned and
    // consulted) even though nothing was actually overwritten — matches the
    // original body's unconditional `suggestionsApplied = true` inside the
    // `if let suggestions` branch.
    #expect(outcome.aliases == ["already-here"])
    #expect(outcome.category == .brand)
    #expect(outcome.suggestionsApplied == true)
  }

  @Test("apply: nil suggestions sets noSuggestionsAvailable, leaves aliases/category untouched")
  func applyNilSuggestionsSetsFlag() {
    let outcome = CustomWordSuggestionFlow.apply(
      suggestions: nil, currentAliases: [], currentCategory: .general)
    #expect(outcome.aliases == [])
    #expect(outcome.category == .general)
    #expect(outcome.suggestionsApplied == false)
    #expect(outcome.noSuggestionsAvailable == true)
  }

  @Test(
    "A newer edit made while suggestion fetching is in flight wins — apply is called with live state, never a pre-fetch snapshot (#1701 Grounded Review Chunk 1 round 2 finding)"
  )
  func liveEditDuringFetchWinsOverFetchedSuggestion() async throws {
    let gate = FlowTestGate()
    let fetchTask: Task<CustomWordSuggestionFlow.FetchResult, Never> = Task {
      await CustomWordSuggestionFlow.fetch(
        canonical: "Saurabh",
        suggest: { _ in
          try? await gate.wait()
          return WordSuggestions(category: .person, suggestedAliases: ["Sourabh"])
        })
    }
    try await gate.waitUntilParked()  // provably mid-fetch, suggestion not yet returned
    // Simulate the user manually typing an alias WHILE the fetch is parked —
    // `fetch` never captured `word.aliases`, so there is nothing stale for it
    // to hand back; the view reads this live value itself, after the await.
    let liveAliasesAfterUserEdit = ["hand-typed"]
    await gate.resume()

    guard case .completed(let suggestions) = await fetchTask.value else {
      Issue.record("expected .completed")
      return
    }
    let outcome = CustomWordSuggestionFlow.apply(
      suggestions: suggestions,
      currentAliases: liveAliasesAfterUserEdit,
      currentCategory: .general)
    #expect(outcome.aliases == ["hand-typed"])
    #expect(outcome.suggestionsApplied == true)
  }

  @Test(
    "fetch: a cancelled calling task reports .cancelled, matching the original's post-await guard")
  func fetchReportsCancelledOnCancellation() async throws {
    let gate = FlowTestGate()
    let task: Task<CustomWordSuggestionFlow.FetchResult, Never> = Task {
      await CustomWordSuggestionFlow.fetch(
        canonical: "x",
        suggest: { _ in
          try? await gate.wait()
          return WordSuggestions(category: .person, suggestedAliases: ["y"])
        })
    }
    try await gate.waitUntilParked()
    task.cancel()
    await gate.resume()
    if case .cancelled = await task.value {
    } else {
      Issue.record("expected .cancelled")
    }
  }

  @Test("removing a sparkled sound-alike chip drops its learned mark, so typing it back in makes it the person's own (#996)")
  func removingAChipDropsItsLearnedMark() {
    var word = CustomWord(
      canonical: "Saira", aliases: ["sarah", "sara"], category: .person,
      learnedAliases: ["sarah"])
    CustomWordSuggestionFlow.removeAlias("sarah", from: &word)
    #expect(word.aliases == ["sara"] && word.learnedAliases.isEmpty)
    // Typed back in before saving: present, and NOT auto-learned any more.
    word.aliases.append("sarah")
    #expect(CustomWordsManager.sanitizeForPersistence(word).learnedAliases.isEmpty)
    #expect(!word.isAutoLearned)
    // Control: removing the plain chip leaves the learned mark on the other.
    var other = CustomWord(
      canonical: "Saira", aliases: ["sarah", "sara"], category: .person,
      learnedAliases: ["sarah"])
    CustomWordSuggestionFlow.removeAlias("sara", from: &other)
    #expect(other.aliases == ["sarah"] && other.learnedAliases == ["sarah"])
  }
}

/// Minimal deadline-bounded rendezvous, local to this file (mirrors
/// `WordSuggestionServiceTests.ResumeGate`; not shared cross-file since both
/// are small, private test-only helpers — `swift-patterns.md` RULE:
/// tests-no-unconditional-continuation-await).
private actor FlowTestGate {
  private(set) var parked = false
  private var released = false

  func wait(timeoutSeconds: Double = 5) async throws {
    parked = true
    try await withThrowingTimeout(seconds: timeoutSeconds) {
      while await self.released == false {
        try Task.checkCancellation()
        await Task.yield()
      }
    }
  }

  func waitUntilParked(timeoutSeconds: Double = 5) async throws {
    try await withThrowingTimeout(seconds: timeoutSeconds) {
      while await self.parked == false {
        try Task.checkCancellation()
        await Task.yield()
      }
    }
  }

  func resume() { released = true }
}
