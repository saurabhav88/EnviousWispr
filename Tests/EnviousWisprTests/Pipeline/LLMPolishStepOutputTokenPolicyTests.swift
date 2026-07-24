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
      LLMPolishStep.outputTokenPolicy(provider: .openAI, model: "gpt-4o-mini", textCount: 500)
        == .providerDefault)
    #expect(
      LLMPolishStep.outputTokenPolicy(provider: .openAI, model: "gpt-5.6-sol", textCount: 500)
        == .providerDefault)
  }

  @Test func geminiSelectsProviderDefault() {
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .gemini, model: "gemini-2.5-flash", textCount: 500)
        == .providerDefault)
  }

  @Test func claudeSelectsFixedRequiredCap() {
    // The Anthropic API requires max_tokens; the value is fixed, not
    // length-scaled.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .claude, model: "claude-haiku-4-5", textCount: 50_000)
        == .capped(LLMConstants.claudeMaxOutputTokens))
  }

  @Test func appleIntelligenceSelectsProviderDefault() {
    // The Apple connector ignores the field entirely (computes its own
    // budget); providerDefault documents that no client ceiling is chosen.
    #expect(
      LLMPolishStep.outputTokenPolicy(
        provider: .appleIntelligence, model: "apple-intelligence", textCount: 500)
        == .providerDefault)
  }

  @Test func ollamaKeepsLengthScaledCapWithPlainFloor() {
    // Non-thinking model: max(count/3 + 100, 256). Just-below and
    // just-above the floor boundary.
    #expect(
      LLMPolishStep.outputTokenPolicy(provider: .ollama, model: "llama3.2", textCount: 300)
        == .capped(256))  // 300/3 + 100 = 200 → floor 256 wins
    #expect(
      LLMPolishStep.outputTokenPolicy(provider: .ollama, model: "llama3.2", textCount: 900)
        == .capped(400))  // 900/3 + 100 = 400 → scale wins
  }

  @Test func ollamaThinkingModelKeepsLargerFloor() {
    // Gemma4 is thinking-capable (#272): 2048 floor.
    #expect(
      LLMPolishStep.outputTokenPolicy(provider: .ollama, model: "gemma4:latest", textCount: 300)
        == .capped(LLMConstants.ollamaThinkingMaxTokens))
  }

  @Test func egOneKeepsCharCountCap() {
    // CJK-safe charCount shape with the 256 floor (#1271).
    #expect(
      LLMPolishStep.outputTokenPolicy(provider: .egOne, model: "eg-1", textCount: 100)
        == .capped(256))
    #expect(
      LLMPolishStep.outputTokenPolicy(provider: .egOne, model: "eg-1", textCount: 3000)
        == .capped(3000))
  }
}
