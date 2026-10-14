import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #3737 Casual mode, the chain step. When this fails, a Casual-mode user still gets a final full stop
/// on some delivery route (polished text, the deterministic fallback), or a snippet loses its own ending.
@MainActor
@Suite("Casual mode chain step (#3737)", .tags(.productOutcome))
struct CasualEndingStepTests {

  private func context(_ text: String, polished: String? = nil, spoken: Bool = false)
    -> TextProcessingContext
  {
    var ctx = TextProcessingContext(text: text, language: "en")
    ctx.polishedText = polished
    ctx.spokenFinalFullStop = spoken
    return ctx
  }

  @Test("Off: the step does not run, so the text is untouched")
  func offDoesNotRun() {
    let step = CasualEndingStep()
    #expect(!step.isEnabled)
    #expect(!step.isEnabled(for: context("See you.")))
  }

  @Test("On: both the deterministic and the polished text lose their final full stop")
  func onStripsBothFields() async throws {
    let step = CasualEndingStep()
    step.casualModeEnabled = true
    let out = try await step.process(context("see you at three.", polished: "See you at three."))
    #expect(out.text == "see you at three")
    #expect(out.polishedText == "See you at three")
  }

  @Test("No polish: polishedText stays nil")
  func nilPolishStaysNil() async throws {
    let step = CasualEndingStep()
    step.casualModeEnabled = true
    let out = try await step.process(context("On my way."))
    #expect(out.text == "On my way")
    #expect(out.polishedText == nil)
  }

  @Test("A full stop the user said is kept on both fields")
  func spokenFullStopKept() async throws {
    let step = CasualEndingStep()
    step.casualModeEnabled = true
    let out = try await step.process(context("See you.", polished: "See you.", spoken: true))
    #expect(out.text == "See you.")
    #expect(out.polishedText == "See you.")
  }

  @Test("A take that ends with a snippet keeps the snippet's own ending")
  func snippetEndingWins() async throws {
    let step = CasualEndingStep()
    step.casualModeEnabled = true
    let sentinel = "EWSNIP0123456789abcdef0123456789abcdef"
    var ctx = context("Thanks \(sentinel)")
    ctx.protectedExpansions = [
      SnippetExpansionRecord(
        sentinel: sentinel, expansion: "Best regards, Sam.", suppressFollowingSentenceEnding: false)
    ]
    var out = try await step.process(ctx)
    SnippetFinalizer.finalize(&out)
    #expect(out.text == "Thanks Best regards, Sam.")

    // A polish that lost the sentinel falls back to the deterministic text, which Casual mode already
    // stripped: the delivered fallback ends without its full stop too.
    ctx.text = "Thanks \(sentinel) see you."
    ctx.polishedText = "Thanks see you."
    out = try await step.process(ctx)
    SnippetFinalizer.finalize(&out)
    #expect(out.polishedText == nil)
    #expect(out.text == "Thanks Best regards, Sam. see you")
    #expect(out.polishFallbackReason == SnippetFinalizer.sentinelLossReason)
  }

  @Test("Casual Ending is the last step of the dictation chain")
  func lastInChain() {
    let steps = LimbSteps(
      snippetExpansion: SnippetExpansionStep(),
      wordCorrection: WordCorrectionStep(),
      learnedWordCheck: LearnedWordCheckStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      englishSpelling: EnglishSpellingStep(target: .text),
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
      englishSpellingAfterPolish: EnglishSpellingStep(target: .polishedText),
      emojiRestore: EmojiRestoreStep(), casualEnding: CasualEndingStep())
    #expect(steps.orderedChain.last is CasualEndingStep)
    #expect(steps.orderedChainForFileImport.last is CasualEndingStep)
  }
}
