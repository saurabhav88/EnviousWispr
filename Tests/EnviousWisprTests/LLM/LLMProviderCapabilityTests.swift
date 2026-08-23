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
    #expect(c.thinkingControl != .unsupported)
    #expect(c.temperaturePolicy == .omit)
    #expect(c.supportsChatCompletions)
  }

  // MARK: - Classic family keeps temperature and gets no reasoning controls

  @Test(arguments: ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-nano", "chatgpt-4o-latest"])
  func classicFamilyIncludesTemperatureWithoutReasoning(model: String) {
    let c = caps(model)
    #expect(c.thinkingControl == .unsupported)
    #expect(c.temperaturePolicy == .include)
    #expect(c.supportsChatCompletions)
  }

  // MARK: - Adversarial: reasoning-prefixed but chat-tuned

  @Test func gpt5ChatVariantIsNotReasoning() {
    let c = caps("gpt-5-chat-latest")
    #expect(c.thinkingControl == .unsupported)
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
    #expect(caps("GPT-5.6-Sol").thinkingControl != .unsupported)
    #expect(!caps("GPT-5-Pro").supportsChatCompletions)
  }

  // MARK: - Empty / unknown ids fail safe as classic

  @Test func emptyAndUnknownIdsAreClassicShaped() {
    for model in ["", "some-future-model"] {
      let c = caps(model)
      #expect(c.thinkingControl == .unsupported)
      #expect(c.temperaturePolicy == .include)
    }
  }

  // MARK: - Other providers

  /// #1770 REPLACES `geminiReasoningPrefixesPreserved`, which asserted that
  /// `gemini-3-flash` supports reasoning. That id does not exist — the real one
  /// is `gemini-3-flash-preview` — and the assertion only passed because the old
  /// implementation prefix-matched `gemini-3`. That is precisely the defect this
  /// change removes: a prefix silently claims authority over ids nobody tested.
  /// Under exact matching a fictional id correctly resolves to `.unsupported`.
  @Test func geminiDialectIsKeyedOnExactIDs() {
    // Gemini 3 Flash tier: string level, `minimal` is a real thinking-off.
    #expect(
      LLMProvider.gemini.modelCapabilities(model: "gemini-3.6-flash").thinkingControl
        == .level("minimal"))
    // Gemini 3 Pro tier: rejects `minimal`, so `low` is the floor.
    #expect(
      LLMProvider.gemini.modelCapabilities(model: "gemini-3.1-pro-preview").thinkingControl
        == .level("low"))
    // 3.7 Flash carries the PRO tier's shape under a Flash name: Google rejects
    // `minimal` on it (400, verified live 2026-08-16), so `low` is its floor and
    // it must not join the Flash-tier grouping above. It was the "untested
    // future id" in the fallback list below until it became the shipped default;
    // this assertion replaces that coverage rather than dropping it.
    #expect(
      LLMProvider.gemini.modelCapabilities(model: "gemini-3.7-flash").thinkingControl
        == .level("low"))
    // Gemini 2.5 Flash tier: integer budget, 0 is legal.
    #expect(
      LLMProvider.gemini.modelCapabilities(model: "gemini-2.5-flash").thinkingControl
        == .budget(0))
    // Gemini 2.5 Pro: rejects budget 0, documented minimum 128.
    #expect(
      LLMProvider.gemini.modelCapabilities(model: "gemini-2.5-pro").thinkingControl
        == .budget(128))

    // Unknown / untested / retired ids reach the fallback and send NOTHING —
    // the shape that succeeded on all eleven working Gemini models measured
    // 2026-07-28/29, not a guarantee about models that do not exist yet.
    // `gemini-3.7-flash` was here as the untested-future-id case and moved to a
    // positive assertion above when it shipped as the default. `gemini-4.0-flash`
    // replaces it so this list keeps covering a plausible-looking id that does
    // not exist yet — the exact shape a prefix match would wrongly capture.
    for unknown in ["gemini-3-flash", "gemini-4.0-flash", "gemini-2.0-flash", "nonsense"] {
      #expect(
        LLMProvider.gemini.modelCapabilities(model: unknown).thinkingControl == .unsupported,
        "\(unknown) must fall through to .unsupported, not inherit an untested value")
      #expect(LLMProvider.gemini.modelCapabilities(model: unknown).thinkingControl == .unsupported)
    }

    // Gemini models always keep temperature.
    #expect(
      LLMProvider.gemini.modelCapabilities(model: "gemini-2.5-pro").temperaturePolicy == .include)
  }

  @Test func localProvidersNeverReasonAndKeepTemperature() {
    for provider in [LLMProvider.ollama, .appleIntelligence, .egOne, .none] {
      let c = provider.modelCapabilities(model: "anything")
      #expect(c.thinkingControl == .unsupported)
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
    #expect(c.thinkingControl == .unsupported)
    #expect(c.temperaturePolicy == .omit)
    #expect(!c.supportsChatCompletions)
  }
}
