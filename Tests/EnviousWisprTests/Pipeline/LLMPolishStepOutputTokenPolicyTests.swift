import EnviousWisprCore
import Testing

@testable import EnviousWisprPipeline

/// #1710: per-provider output-token policy selection. Pure-function coverage
/// of `LLMPolishStep.outputTokenPolicy` — no config construction, no network.
@Suite("LLMPolishStep output-token policy")
struct LLMPolishStepOutputTokenPolicyTests {

  @Test func openAISelectsProviderDefault() {
    // Reasoning and non-reasoning families alike: no client ceiling.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .openAI, model: "gpt-4o-mini", textCount: 500, thinks: false)
        == .providerDefault)
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .openAI, model: "gpt-5.6-sol", textCount: 500, thinks: false)
        == .providerDefault)
  }

  @Test func geminiSelectsProviderDefault() {
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .gemini, model: "gemini-2.5-flash", textCount: 500, thinks: false)
        == .providerDefault)
  }

  @Test func claudeSelectsFixedRequiredCap() {
    // The Anthropic API requires max_tokens; the value is fixed, not
    // length-scaled.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .claude, model: "claude-haiku-4-5", textCount: 50_000, thinks: false)
        == .capped(LLMConstants.claudeMaxOutputTokens))
  }

  @Test func appleIntelligenceSelectsProviderDefault() {
    // The Apple connector ignores the field entirely (computes its own
    // budget); providerDefault documents that no client ceiling is chosen.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .appleIntelligence, model: "apple-intelligence", textCount: 500, thinks: false)
        == .providerDefault)
  }

  @Test func ollamaKeepsLengthScaledCapWithPlainFloor() {
    // Non-thinking model: max(count/3 + 100, 256). Just-below and
    // just-above the floor boundary.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .ollama, model: "llama3.2", textCount: 300, thinks: false)
        == .capped(256))  // 300/3 + 100 = 200 → floor 256 wins
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .ollama, model: "llama3.2", textCount: 900, thinks: false)
        == .capped(400))  // 900/3 + 100 = 400 → scale wins
  }

  @Test func ollamaThinkingModelKeepsLargerFloor() {
    // #1914: the floor now follows the daemon's reported capability, not the
    // model name. Same 2048 outcome as #272, reached from `thinks: true`.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .ollama, model: "gemma4:latest", textCount: 300, thinks: true)
        == .capped(LLMConstants.ollamaThinkingMaxTokens))
  }

  /// #1914 retirement freeze. The four families that were hard-coded in the
  /// retired prefix list must still receive the large floor — but now because
  /// the daemon SAYS they think, not because their name matched a list. All four
  /// were verified live 2026-08-01 to report the `thinking` capability (`qwen3`
  /// and `deepseek-r1` as local builds).
  @Test(
    "the four formerly hard-coded families keep the thinking floor via capability",
    arguments: ["gemma4:latest", "gemma4:8b", "qwen3", "qwen3:7b", "deepseek-r1", "gpt-oss:20b"])
  func retiredPrefixFamiliesKeepFloorViaCapability(model: String) {
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .ollama, model: model, textCount: 300, thinks: true)
        == .capped(LLMConstants.ollamaThinkingMaxTokens))
  }

  /// The load-bearing half of the retirement. These names would have matched
  /// nothing in the old list AND report no thinking capability, so they keep the
  /// tight floor. Without this, an always-thinking implementation would pass the
  /// test above while silently handing every model the large budget.
  @Test(
    "models the daemon reports as non-thinking keep the tight floor",
    arguments: ["llama3.2", "mistral", "gemma2:2b", "qwen2.5:7b", "tinyllama"])
  func nonThinkingModelsKeepTightFloor(model: String) {
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .ollama, model: model, textCount: 300, thinks: false)
        == .capped(LLMConstants.ollamaMaxTokens))
  }

  /// The model NAME must no longer influence Ollama's budget at all. The same
  /// name yields both floors depending only on the reported capability — which
  /// is exactly what a surviving name-based fallback would break.
  @Test func ollamaBudgetIgnoresModelNameEntirely() {
    // A name that used to match the prefix list, reported as NOT thinking.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .ollama, model: "gemma4:latest", textCount: 300, thinks: false)
        == .capped(LLMConstants.ollamaMaxTokens))
    // A name that never matched the list, reported as thinking.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .ollama, model: "some-unknown-model:7b", textCount: 300, thinks: true)
        == .capped(LLMConstants.ollamaThinkingMaxTokens))
  }

  /// The length scale still dominates above the floor for a thinking model, so
  /// the larger floor cannot silently cap a long dictation.
  @Test func thinkingFloorDoesNotCapLongDictations() {
    // 9000/3 + 100 = 3100, above the 2048 floor.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .ollama, model: "qwen3", textCount: 9000, thinks: true)
        == .capped(3100))
  }

  @Test func egOneKeepsCharCountCap() {
    // CJK-safe charCount shape with the 256 floor (#1271).
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .egOne, model: "eg-1", textCount: 100, thinks: false)
        == .capped(256))
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .egOne, model: "eg-1", textCount: 3000, thinks: false)
        == .capped(3000))
  }
}
