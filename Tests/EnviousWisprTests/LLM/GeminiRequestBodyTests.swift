import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("Gemini request body")
struct GeminiRequestBodyTests {
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

  @Test func modelProbeRequestBodyDisablesProviderLogging() {
    let body = LLMModelDiscovery.makeGeminiProbeRequestBody()
    #expect(body["store"] as? Bool == false)
  }
}
