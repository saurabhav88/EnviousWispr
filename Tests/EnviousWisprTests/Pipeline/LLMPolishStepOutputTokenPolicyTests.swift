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
        provider: .openAI, textCount: 500, thinks: false)
        == .providerDefault)
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .openAI, textCount: 500, thinks: false)
        == .providerDefault)
  }

  @Test func geminiSelectsProviderDefault() {
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .gemini, textCount: 500, thinks: false)
        == .providerDefault)
  }

  @Test func claudeSelectsFixedRequiredCap() {
    // The Anthropic API requires max_tokens; the value is fixed, not
    // length-scaled.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .claude, textCount: 50_000, thinks: false)
        == .capped(LLMConstants.claudeMaxOutputTokens))
  }

  @Test func appleIntelligenceSelectsProviderDefault() {
    // The Apple connector ignores the field entirely (computes its own
    // budget); providerDefault documents that no client ceiling is chosen.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .appleIntelligence, textCount: 500, thinks: false)
        == .providerDefault)
  }

  @Test func ollamaKeepsLengthScaledCapWithPlainFloor() {
    // Non-thinking model: max(count/3 + 100, 256). Just-below and
    // just-above the floor boundary.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .ollama, textCount: 300, thinks: false)
        == .capped(256))  // 300/3 + 100 = 200 → floor 256 wins
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .ollama, textCount: 900, thinks: false)
        == .capped(400))  // 900/3 + 100 = 400 → scale wins
  }

  @Test func ollamaThinkingModelKeepsLargerFloor() {
    // #1914: the floor now follows the daemon's reported capability, not the
    // model name. Same 2048 outcome as #272, reached from `thinks: true`.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .ollama, textCount: 300, thinks: true)
        == .capped(LLMConstants.ollamaThinkingMaxTokens))
  }

  /// The length scale still dominates above the floor for a thinking model, so
  /// the larger floor cannot silently cap a long dictation.
  @Test func thinkingFloorDoesNotCapLongDictations() {
    // 9000/3 + 100 = 3100, above the 2048 floor.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .ollama, textCount: 9000, thinks: true)
        == .capped(3100))
  }

  @Test func egOneKeepsCharCountCap() {
    // CJK-safe charCount shape with the 256 floor (#1271).
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .egOne, textCount: 100, thinks: false)
        == .capped(256))
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .egOne, textCount: 3000, thinks: false)
        == .capped(3000))
  }
}
