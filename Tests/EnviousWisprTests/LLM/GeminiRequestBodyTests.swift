import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("Gemini request body")
struct GeminiRequestBodyTests {
  // MARK: - Output-token policy (#1710)

  private func config(outputTokens: OutputTokenPolicy, budget: Int? = nil)
    -> LLMProviderConfig
  {
    LLMProviderConfig(
      model: "gemini-2.5-flash", apiKeyKeychainId: "gemini-api-key",
      outputTokens: outputTokens, temperature: 0, thinking: budget.map { .budget($0) })
  }

  @Test func providerDefaultOmitsMaxOutputTokens() {
    let generationConfig = GeminiConnector.makeGenerationConfig(
      config: config(outputTokens: .providerDefault))
    #expect(generationConfig["maxOutputTokens"] == nil)
    #expect(generationConfig["temperature"] as? Double == 0)
  }

  @Test func cappedSerializesExactValue() {
    let generationConfig = GeminiConnector.makeGenerationConfig(
      config: config(outputTokens: .capped(4096)))
    #expect(generationConfig["maxOutputTokens"] as? Int == 4096)
  }

  @Test func thinkingBudgetPassesThroughUnchanged() {
    let generationConfig = GeminiConnector.makeGenerationConfig(
      config: config(outputTokens: .providerDefault, budget: 0))
    let thinking = generationConfig["thinkingConfig"] as? [String: Int]
    #expect(thinking?["thinkingBudget"] == 0)
  }

  // MARK: - Thinking dialect (#1770)

  private func config(thinking: ResolvedThinking?) -> LLMProviderConfig {
    LLMProviderConfig(
      model: "gemini-3.6-flash", apiKeyKeychainId: "gemini-api-key",
      outputTokens: .providerDefault, temperature: 0, thinking: thinking)
  }

  /// Each dialect must emit its OWN key and only its own key. Sending
  /// `thinkingBudget` to a Gemini 3 model is the HTTP 400 this fixes, so the
  /// absence of the wrong key is as load-bearing as the presence of the right one.
  @Test func eachDialectEmitsExactlyItsOwnKey() {
    let level = GeminiConnector.makeGenerationConfig(config: config(thinking: .level("minimal")))
    let levelCfg = level["thinkingConfig"] as? [String: Any]
    #expect(levelCfg?["thinkingLevel"] as? String == "minimal")
    #expect(levelCfg?["thinkingBudget"] == nil)

    let budget = GeminiConnector.makeGenerationConfig(config: config(thinking: .budget(8192)))
    let budgetCfg = budget["thinkingConfig"] as? [String: Any]
    #expect(budgetCfg?["thinkingBudget"] as? Int == 8192)
    #expect(budgetCfg?["thinkingLevel"] == nil)
  }

  /// The fail-open case, asserted positively: an unknown model sends no
  /// `thinkingConfig` at all — the shape that succeeded on all eleven working
  /// Gemini models measured 2026-07-28/29. Future models are unverified by
  /// construction; this is the safest first attempt, not a guarantee.
  @Test func unsupportedSendsNoThinkingKeyAtAll() {
    let generationConfig = GeminiConnector.makeGenerationConfig(config: config(thinking: nil))
    #expect(generationConfig["thinkingConfig"] == nil)
    // Everything else about the request is untouched.
    #expect(generationConfig["temperature"] as? Double == 0)
  }

  /// OpenAI's dialect can never reach Gemini serialization.
  @Test func effortDialectIsIgnoredByGemini() {
    let generationConfig = GeminiConnector.makeGenerationConfig(
      config: config(thinking: .effort("low")))
    #expect(generationConfig["thinkingConfig"] == nil)
  }

  @Test func polishRequestBodyDisablesProviderLogging() {
    let body = GeminiConnector.makeRequestBody(
      text: "hello",
      systemPrompt: "polish",
      generationConfig: ["maxOutputTokens": 5]
    )

    #expect(body["store"] as? Bool == false)
  }

  @Test func polishRequestBodyPreservesTranscriptShape() {
    let body = GeminiConnector.makeRequestBody(
      text: "hello",
      systemPrompt: "polish",
      generationConfig: ["maxOutputTokens": 5]
    )

    let contents = body["contents"] as? [[String: Any]]
    let parts = contents?.first?["parts"] as? [[String: String]]
    #expect(parts?.first?["text"] == "hello")
  }

  @Test func polishRequestBodyUsesPlaceholderFallbackForEmptyText() {
    let body = GeminiConnector.makeRequestBody(
      text: "",
      systemPrompt: "polish ${transcript}",
      generationConfig: ["maxOutputTokens": 5]
    )

    let contents = body["contents"] as? [[String: Any]]
    let parts = contents?.first?["parts"] as? [[String: String]]
    #expect(parts?.first?["text"] == "Polish the transcript per the system instructions.")
  }

  @Test func warmupRequestBodyDisablesProviderLogging() {
    let body = LLMNetworkSession.makeGeminiWarmupRequestBody()
    #expect(body["store"] as? Bool == false)
  }

  @Test func modelProbeRequestBodyKeepsLiteralCapOfFive() {
    let body = LLMModelDiscovery.makeGeminiProbeRequestBody()
    let generationConfig = body["generationConfig"] as? [String: Any]
    #expect(generationConfig?["maxOutputTokens"] as? Int == 5)
  }

  @Test func modelProbeRequestBodyDisablesProviderLogging() {
    let body = LLMModelDiscovery.makeGeminiProbeRequestBody()
    #expect(body["store"] as? Bool == false)
  }
}
