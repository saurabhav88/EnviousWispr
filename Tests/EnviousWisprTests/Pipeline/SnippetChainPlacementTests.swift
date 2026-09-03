import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #628 — where the snippet step sits in the chain, and what a user without snippets pays.
///
/// Two classes, deliberately split.
///
/// The ORDER test is `.driftGuard`: it fails when we change our own code, which is the point.
/// The order is not arbitrary — every position in it was argued for in a different issue — and
/// nothing else in the codebase would notice if a future change reordered it.
///
/// The empty-store test is `.productOutcome`: it is the promise that shipping this feature
/// costs nothing to the user who never opens it. Premise P4 in the plan, and it is proved by
/// RUNNING the chain rather than by reading that the step is disabled — reaching a guard is not
/// reaching its branch.
// One class on the suite, as the inventory requires. `.productOutcome` rather than
// `.driftGuard`: the empty-store test is the load-bearing one — it is the promise that a user
// who never opens Snippets is unaffected — and the order freeze is the supporting detail.
@Suite("Snippet chain placement (#628)", .tags(.productOutcome))
struct SnippetChainPlacementTests {

  @MainActor
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

  @Test("The chain order is frozen, and snippet expansion is first")
  @MainActor
  func chainOrderIsFrozen() {
    let names = makeSteps().orderedChain.map(\.name)

    #expect(
      names == [
        "Snippet Expansion",
        "Word Correction",
        "Filler Removal",
        "Emoji Formatter",
        "Inverse Text Normalization",
        "LLM Polish",
        "Emoji Restore",
      ])
  }

  /// The structural half. `orderedChain` only removes the drift risk if BOTH paths actually
  /// read it — a second literal array reintroduced in either file would compile, pass every
  /// behavioural test, and silently give recovery a different chain from live.
  ///
  /// Reading the source is the right instrument here: the question is "does a second list
  /// exist", and no runtime assertion can observe a list nobody called.
  @Test("Both chain callers read the single ordered authority")
  func bothCallersUseTheSingleAuthority() throws {
    for file in ["KernelFinalizationWiring.swift", "RecoveryTextProcessor.swift"] {
      // Walk UP to the package root rather than counting `..` hops. A hop count is a
      // measurement of where this test file currently sits, so moving the file silently
      // repoints the read at a path that does not exist — which is a FAILING test on correct
      // code, the direction that invites "fixing" a machine that was already right.
      var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
        let parent = root.deletingLastPathComponent()
        try #require(parent.path != root.path, "walked past the filesystem root looking for Package.swift")
        root = parent
      }
      let url = root.appendingPathComponent("Sources/EnviousWisprPipeline/\(file)")
      let source = try String(contentsOf: url, encoding: .utf8)

      #expect(source.contains("steps: steps.orderedChain"), "\(file) must use the shared chain")
      #expect(
        !source.contains("steps.wordCorrection, steps.fillerRemoval"),
        "\(file) has re-inlined a second chain array")
    }
  }

  /// P4. Run the SAME text through the chain with the snippet step present and absent, and
  /// require the outputs to be identical — not merely that the step reported itself disabled.
  @Test("An empty snippet store leaves the chain output byte-identical")
  @MainActor
  func emptyStoreChangesNothing() async throws {
    let steps = makeSteps()
    // Left at `.empty`, which is what a user who has never opened Snippets has.
    #expect(steps.snippetExpansion.isEnabled == false)

    let runner = TextProcessingRunner()
    let input = "backslash my email address, and the path is backslash users"

    let withStep = try await runner.run(
      rawText: input, evidence: .locked("en"), targetAppName: nil, steps: steps.orderedChain)
    let withoutStep = try await runner.run(
      rawText: input, evidence: .locked("en"), targetAppName: nil,
      steps: steps.orderedChain.filter { $0.name != "Snippet Expansion" })

    #expect(withStep.context.text == withoutStep.context.text)
    #expect(withStep.context.polishedText == withoutStep.context.polishedText)
    #expect(withStep.context.protectedExpansions.isEmpty)
    #expect(withStep.context.pipelineFellBackToRaw == withoutStep.context.pipelineFellBackToRaw)
  }

  /// The other half of P4: with a vocabulary loaded, the step transforms. Without this the
  /// test above passes against a step that can NEVER fire, which is a guard that is green
  /// because it is broken.
  ///
  /// Driven through `process` directly, NOT through the runner, and that is deliberate. Every
  /// step carries a wall-clock budget (`maxDuration`, 50 ms here), and the runner silently
  /// skips a step that exceeds it, keeping that step's input. Under a full parallel suite this
  /// machine can miss 50 ms of pure string work, so a chain-level assertion here would fail on
  /// correct code — which it did, once, at 56 seconds. The load-dependent assertion is the
  /// defect, not the budget: the question this test asks is what the STEP does, and the runner's
  /// timing is a different question with its own coverage.
  @Test("A loaded snippet store arms the step")
  @MainActor
  func loadedStoreArmsTheStep() async throws {
    let step = SnippetExpansionStep()
    step.snippetVocabulary = SnippetVocabulary(
      snippets: [Snippet(trigger: "my email address", expansion: "sam@example.com")],
      keyword: SnippetVocabulary.defaultKeyword,
      generation: 1)

    #expect(step.isEnabled)

    let context = TextProcessingContext(
      text: "email me at backslash my email address", language: "en")
    let result = try await step.process(context)

    #expect(result.protectedExpansions.count == 1)
    #expect(result.protectedExpansions.first?.expansion == "sam@example.com")
    // The chain carries the SENTINEL, not the address: the address must not reach polish.
    #expect(!result.text.contains("sam@example.com"))
    #expect(result.text.contains(try #require(result.protectedExpansions.first).sentinel))

    var resolved = result
    SnippetFinalizer.finalize(&resolved)
    #expect(resolved.text == "email me at sam@example.com")
  }
}
