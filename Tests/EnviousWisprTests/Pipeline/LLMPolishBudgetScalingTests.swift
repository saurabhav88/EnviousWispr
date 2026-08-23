import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #1770: the polish deadline scales with the transcript for Gemini.
///
/// A flat 5 s was timing out the measured long dictations (11,324 chars at
/// 6.12 s, 66,896 at 50.65 s; the last case under budget was 4,605 at 2.69 s) — measured live, a 10-minute dictation polishes in 6.12 s and the
/// longest transcript we have recorded in 50.65 s. A flat LARGER number was
/// rejected because it would slow the common case (p50 is 8 seconds of speech)
/// down to rescue the 0.1% tail.
///
/// One table-driven test rather than "long > short": that weaker assertion
/// would pass with the base, the divisor or the ceiling wrong.
///
/// #1831 removed the second (60 s) base along with the Deep-reasoning toggle
/// that was its only trigger, so every Gemini request now shares one base.
@MainActor
@Suite("Gemini polish budget scales with transcript length (#1770)")
struct LLMPolishBudgetScalingTests {

  private func step(model: String, provider: LLMProvider = .gemini) -> LLMPolishStep {
    let s = LLMPolishStep(keychainManager: KeychainManager())
    s.llmProvider = provider
    s.llmModel = model
    return s
  }

  /// Returns the `Duration` itself so assertions compare exact values rather
  /// than a float tolerance that could mask a wrong base or divisor.
  private func budget(_ s: LLMPolishStep, chars: Int) -> Duration {
    s.maxDuration(
      for: TextProcessingContext(text: String(repeating: "a", count: chars), language: "en"))
  }

  /// Exact expected values, not display rounding: `base + chars / 500`.
  @Test("base 5s plus one second per 500 characters")
  func budgetScalesWithLength() {
    let s = step(model: "gemini-3.6-flash")
    // ~20 words. Preserves today's short-dictation failure speed almost exactly.
    #expect(budget(s, chars: 110) == .seconds(5 + 110.0 / 500))
    // p99 of real dictations.
    #expect(budget(s, chars: 1709) == .seconds(5 + 1709.0 / 500))
    // A 10-minute dictation — 6.12s measured, so 4.5x headroom.
    #expect(budget(s, chars: 11324) == .seconds(5 + 11324.0 / 500))
    // The longest transcript ever recorded — 50.65s measured, 2.7x headroom.
    #expect(budget(s, chars: 66896) == .seconds(5 + 66896.0 / 500))
  }

  /// Beyond this the transport terminates the attempt anyway, so a larger
  /// logical budget only buys another long attempt.
  @Test("the budget is capped at the transport's 180s resource limit")
  func budgetIsCapped() {
    let s = step(model: "gemini-3.6-flash")
    #expect(budget(s, chars: 1_000_000) == .seconds(180))
  }

  // REMOVED by #1831: `deepModeUsesLargerBase` asserted that a deep request
  // got a 60 s base to cover a measured 42.2-42.4 s of pre-first-byte
  // thinking. Nothing can request that shape now — the capability table holds
  // one value per model — so there is no behaviour left for it to guard. The
  // measurement itself is preserved at the constant it justified, in
  // `LLMPolishStep.maxDuration`, because it is the evidence for the removal
  // rather than a description of live code.

  /// The base must not vary by MODEL. Previously this asserted the narrower
  /// property that an unverified model could not inherit the deep base while
  /// the toggle was on; with one base remaining, the durable claim is that a
  /// model absent from the capability table is budgeted identically to one
  /// present in it. Kept rather than deleted because it is the case that would
  /// go red if anyone reintroduced a per-model base.
  @Test("a model absent from the capability table gets the same base")
  func unlistedModelGetsTheSameBase() {
    let listed = step(model: "gemini-3.6-flash")
    let unlisted = step(model: "gemini-4.0-flash-imaginary")
    #expect(budget(unlisted, chars: 110) == .seconds(5 + 110.0 / 500))
    #expect(budget(unlisted, chars: 110) == budget(listed, chars: 110))
  }

  /// Only Gemini scales. OpenAI and Claude keep their fixed budgets; widening
  /// them without measuring their streaming behaviour is #1833.
  @Test("other providers keep their fixed budgets regardless of length")
  func otherProvidersUnchanged() {
    let openAI = step(model: "gpt-4o-mini", provider: .openAI)
    #expect(budget(openAI, chars: 110) == .seconds(5))
    #expect(budget(openAI, chars: 66896) == .seconds(5))

    let claude = step(model: "claude-haiku-4-5", provider: .claude)
    #expect(budget(claude, chars: 66896) == .seconds(15))

    let ollama = step(model: "llama3.2", provider: .ollama)
    #expect(budget(ollama, chars: 66896) == .seconds(15))
  }

  /// The five non-LLM steps inherit the protocol default, which returns their
  /// fixed `maxDuration` — they must not have been disturbed by adding the
  /// context-aware form.
  @Test("fixed-duration steps are unaffected by the context-aware form")
  func fixedDurationStepsUnchanged() {
    let context = TextProcessingContext(text: String(repeating: "a", count: 66896), language: "en")
    let filler = FillerRemovalStep()
    #expect(filler.maxDuration(for: context) == filler.maxDuration)
    let itn = InverseTextNormalizationStep()
    #expect(itn.maxDuration(for: context) == itn.maxDuration)
    let wordCorrection = WordCorrectionStep()
    #expect(wordCorrection.maxDuration(for: context) == .seconds(3))
    let emojiFormatter = EmojiFormatterStep()
    #expect(emojiFormatter.maxDuration(for: context) == emojiFormatter.maxDuration)
    let emojiRestore = EmojiRestoreStep()
    #expect(emojiRestore.maxDuration(for: context) == emojiRestore.maxDuration)
  }
}
