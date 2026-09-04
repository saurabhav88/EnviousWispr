import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #1770: the polish deadline scales with the transcript for Gemini.
/// #2093: the base moved 5s -> 15s and OpenAI joined the scaled form.
///
/// A flat 5 s was timing out the measured long dictations (11,324 chars at
/// 6.12 s, 66,896 at 50.65 s; the last case under budget was 4,605 at 2.69 s).
///
/// #1770 rejected a flat LARGER number on the ground that it would slow the
/// common case to rescue the 0.1% tail. **#2093 raised the base anyway, because
/// that reasoning did not survive its own evidence:** the failures are not in a
/// long tail at all. Median dictation at a production timeout is 106 characters
/// and 26 of 54 are under 100, so the BASE was cutting off the common case, not
/// protecting it. Raising it costs nothing on a healthy call — the budget is a
/// ceiling, not a delay — and only lengthens the wait when the provider was
/// never going to answer.
///
/// One table-driven test rather than "long > short": that weaker assertion
/// would pass with the base, the divisor or the ceiling wrong.
///
/// #1831 removed the second (60 s) base along with the Deep-reasoning toggle
/// that was its only trigger, so every Gemini request now shares one base.
@MainActor
@Suite("Cloud polish budget scales with transcript length (#1770, #2093)")
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
  ///
  /// #2093 swept the RANGE the value really takes rather than testing at one
  /// nominal length: 0 and 1 are the degenerate ends a `count`-derived term can
  /// get wrong, and 106 is the MEASURED median dictation length at a production
  /// timeout — the case the whole issue is about, which no earlier row covered.
  @Test("base 15s plus one second per 500 characters, across the real range")
  func budgetScalesWithLength() {
    let s = step(model: "gemini-3.6-flash")
    // Degenerate ends.
    #expect(budget(s, chars: 0) == .seconds(15))
    #expect(budget(s, chars: 1) == .seconds(15 + 1.0 / 500))
    // The measured median dictation at a production timeout (#2093).
    #expect(budget(s, chars: 106) == .seconds(15 + 106.0 / 500))
    // ~20 words.
    #expect(budget(s, chars: 110) == .seconds(15 + 110.0 / 500))
    // p99 of real dictations.
    #expect(budget(s, chars: 1709) == .seconds(15 + 1709.0 / 500))
    // A 10-minute dictation — 6.12s measured.
    #expect(budget(s, chars: 11324) == .seconds(15 + 11324.0 / 500))
    // The longest transcript ever recorded — 50.65s measured.
    #expect(budget(s, chars: 66896) == .seconds(15 + 66896.0 / 500))
  }

  /// #2093: OpenAI now scales identically to Gemini, closing the OpenAI half of
  /// #1833. Asserted at the same lengths so a divergence between the two cloud
  /// providers cannot hide behind a different test shape.
  @Test("OpenAI scales identically to Gemini (#2093)")
  func openAIScalesLikeGemini() {
    let openAI = step(model: "gpt-5.4-mini", provider: .openAI)
    let gemini = step(model: "gemini-3.6-flash")
    for chars in [0, 1, 106, 110, 1709, 11324, 66896] {
      #expect(budget(openAI, chars: chars) == .seconds(15 + Double(chars) / 500))
      #expect(budget(openAI, chars: chars) == budget(gemini, chars: chars))
    }
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
    #expect(budget(unlisted, chars: 110) == .seconds(15 + 110.0 / 500))
    #expect(budget(unlisted, chars: 110) == budget(listed, chars: 110))
  }

  /// #2093: the set that scales is now {gemini, openAI}. Claude keeps its FIXED
  /// 15s deliberately — #158 measured that provider directly (9.16s worst real
  /// call), so widening it here would be a change nothing measured. This is the
  /// remaining half of #1833.
  @Test("non-scaling providers keep their fixed budgets regardless of length")
  func otherProvidersUnchanged() {
    let claude = step(model: "claude-haiku-4-5", provider: .claude)
    #expect(budget(claude, chars: 110) == .seconds(15))
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
