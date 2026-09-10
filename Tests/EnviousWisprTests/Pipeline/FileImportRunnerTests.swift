import EnviousWisprLLM
import Testing

@testable import EnviousWisprPipeline

/// #2648 — the chain one part of an imported transcript runs through.
///
/// **When this fails, an imported recording of somebody else's meeting comes back with the user's saved
/// snippet text substituted into it, or with a limb silently missing.** Product coverage.
@Suite(.tags(.productOutcome))
@MainActor
struct FileImportRunnerTests {

  private func makeSteps() -> LimbSteps {
    LimbSteps(
      snippetExpansion: SnippetExpansionStep(),
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
      emojiRestore: EmojiRestoreStep())
  }

  /// **Snippet expansion must not run on an imported file.** A trigger word spoken by somebody in a
  /// recording would be replaced by the user's saved text, putting words the speaker never said into a
  /// transcript of their speech.
  ///
  /// Asserted STRUCTURALLY — by type, over the real chain — rather than by comparing against a list
  /// written here. A list written here would be a second opinion that can drift.
  @Test("the import chain contains no snippet expansion")
  func importChainExcludesSnippetExpansion() {
    let steps = makeSteps()

    #expect(!steps.orderedChainForFileImport.contains { $0 is SnippetExpansionStep })
    #expect(
      steps.orderedChain.contains { $0 is SnippetExpansionStep },
      "the control: the ordinary chain DOES include it, so the assertion above is about the filter")
  }

  /// **Every other limb must still run**, and the import chain must not be a hand-written list that
  /// drifts from the one place the order is declared.
  ///
  /// This is the row that fails when someone adds a limb to `orderedChain` and forgets imports: the
  /// counts stop agreeing. It is derived from the producer on both sides, so it cannot be satisfied by
  /// updating a literal.
  @Test("the import chain is the ordinary chain minus exactly one step, in the same order")
  func importChainIsDerivedFromTheOrderedChain() {
    let steps = makeSteps()
    let ordinary = steps.orderedChain
    let imported = steps.orderedChainForFileImport

    #expect(imported.count == ordinary.count - 1)
    let ordinaryWithoutSnippets = ordinary.filter { !($0 is SnippetExpansionStep) }
    #expect(
      zip(imported, ordinaryWithoutSnippets).allSatisfy {
        ObjectIdentifier(type(of: $0)) == ObjectIdentifier(type(of: $1))
      },
      "the import chain is not the ordinary chain's order with the snippet step removed")
  }

  /// A part cannot run before the import's configuration is frozen. This is a programming error rather
  /// than a user-facing one, and it fails loudly instead of running under whatever the defaults happen
  /// to be — which would silently polish with the wrong provider.
  @Test("a part refuses to run before the import is configured")
  func partRefusesBeforeFreeze() async {
    let runner = FileImportRunner(keychainManager: KeychainManager())

    await #expect(throws: FileImportRunnerError.notConfigured) {
      _ = try await runner.process(part: "some words")
    }
  }

  /// The floor: a part whose polish did not land shows its deterministic text and is MARKED, never
  /// hidden and never dropped.
  @Test("an unpolished part reports itself as unpolished and still carries text")
  func unpolishedPartKeepsItsText() {
    let outcome = FileImportRunner.PartOutcome(
      text: "the deterministic floor", polishedText: nil, polishError: "provider unavailable")

    #expect(outcome.displayText == "the deterministic floor")
    #expect(outcome.isUnpolished)
  }

  @Test("a polished part shows the polished text")
  func polishedPartShowsPolish() {
    let outcome = FileImportRunner.PartOutcome(
      text: "the floor", polishedText: "The polished sentence.", polishError: nil)

    #expect(outcome.displayText == "The polished sentence.")
    #expect(!outcome.isUnpolished)
  }
}
