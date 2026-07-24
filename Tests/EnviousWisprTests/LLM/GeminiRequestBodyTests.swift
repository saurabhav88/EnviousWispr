import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("Gemini request body")
struct GeminiRequestBodyTests {
  // MARK: - Output-token policy (#1710)

  private func config(outputTokens: OutputTokenPolicy, thinkingBudget: Int? = nil)
    -> LLMProviderConfig
  {
    LLMProviderConfig(
      model: "gemini-2.5-flash", apiKeyKeychainId: "gemini-api-key",
      outputTokens: outputTokens, temperature: 0, thinkingBudget: thinkingBudget,
      reasoningEffort: nil)
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
      config: config(outputTokens: .providerDefault, thinkingBudget: 0))
    let thinking = generationConfig["thinkingConfig"] as? [String: Int]
    #expect(thinking?["thinkingBudget"] == 0)
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
