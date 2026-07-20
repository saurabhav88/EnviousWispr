import EnviousWisprCore
import Testing

@testable import EnviousWisprLLM

/// #1330: the capability authority. Reasoning support, temperature policy,
/// and Chat Completions eligibility are three INDEPENDENT facts — the
/// adversarial rows below each place a model in its non-intended class
/// (matcher-set discipline): a reasoning-prefixed chat variant, a
/// gpt-prefixed Responses-only model, a classic model that must keep
/// temperature.
@Suite("LLM model capability authority")
struct LLMProviderCapabilityTests {

  private func caps(_ model: String) -> LLMModelCapabilities {
    LLMProvider.openAI.modelCapabilities(model: model)
  }

  // MARK: - Reasoning family (gpt-5 generation + o-series)

  @Test(arguments: [
    "gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-5.1", "gpt-5.5",
    "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
    "o1", "o1-mini", "o3", "o3-mini", "o4-mini",
  ])
  func reasoningFamilySupportsReasoningAndOmitsTemperature(model: String) {
    let c = caps(model)
    #expect(c.supportsReasoning)
    #expect(c.temperaturePolicy == .omit)
    #expect(c.supportsChatCompletions)
  }

  // MARK: - Classic family keeps temperature and gets no reasoning controls

  @Test(arguments: ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-nano", "chatgpt-4o-latest"])
  func classicFamilyIncludesTemperatureWithoutReasoning(model: String) {
    let c = caps(model)
    #expect(!c.supportsReasoning)
    #expect(c.temperaturePolicy == .include)
    #expect(c.supportsChatCompletions)
  }

  // MARK: - Adversarial: reasoning-prefixed but chat-tuned

  @Test func gpt5ChatVariantIsNotReasoning() {
    let c = caps("gpt-5-chat-latest")
    #expect(!c.supportsReasoning)
    #expect(c.temperaturePolicy == .include)
    #expect(c.supportsChatCompletions)
  }

  // MARK: - Adversarial: gpt-prefixed but Responses-API-only

  @Test(arguments: ["gpt-5-pro", "gpt-5.5-pro-2026-04-23", "gpt-5-codex", "gpt-5.3-codex-spark"])
  func responsesOnlyFamiliesAreNotChatCompletionsEligible(model: String) {
    #expect(!caps(model).supportsChatCompletions)
  }

  // MARK: - Case-insensitive matching (persisted strings may vary)

  @Test func matchingIsCaseInsensitive() {
    #expect(caps("GPT-5.6-Sol").supportsReasoning)
    #expect(!caps("GPT-5-Pro").supportsChatCompletions)
  }

  // MARK: - Empty / unknown ids fail safe as classic

  @Test func emptyAndUnknownIdsAreClassicShaped() {
    for model in ["", "some-future-model"] {
      let c = caps(model)
      #expect(!c.supportsReasoning)
      #expect(c.temperaturePolicy == .include)
    }
  }

  // MARK: - Other providers

  @Test func geminiReasoningPrefixesPreserved() {
    #expect(LLMProvider.gemini.modelCapabilities(model: "gemini-2.5-pro").supportsReasoning)
    #expect(LLMProvider.gemini.modelCapabilities(model: "gemini-3-flash").supportsReasoning)
    #expect(!LLMProvider.gemini.modelCapabilities(model: "gemini-2.0-flash").supportsReasoning)
    // Gemini models always keep temperature.
    #expect(
      LLMProvider.gemini.modelCapabilities(model: "gemini-2.5-pro").temperaturePolicy == .include)
  }

  @Test func localProvidersNeverReasonAndKeepTemperature() {
    for provider in [LLMProvider.ollama, .appleIntelligence, .egOne, .none] {
      let c = provider.modelCapabilities(model: "anything")
      #expect(!c.supportsReasoning)
      #expect(c.temperaturePolicy == .include)
    }
  }

  // MARK: - Claude (#158): never reasons, always omits temperature

  @Test(arguments: [
    "claude-haiku-4-5", "claude-haiku-4-5-20251001", "claude-sonnet-5",
    "claude-opus-4-8", "claude-fable-5",
  ])
  func claudeNeverReasonsAndOmitsTemperature(model: String) {
    let c = LLMProvider.claude.modelCapabilities(model: model)
    #expect(!c.supportsReasoning)
    #expect(c.temperaturePolicy == .omit)
    #expect(!c.supportsChatCompletions)
  }
}
