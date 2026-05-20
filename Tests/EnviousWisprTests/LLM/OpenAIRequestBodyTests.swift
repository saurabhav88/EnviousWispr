import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("OpenAI request body")
struct OpenAIRequestBodyTests {
  @Test func modelProbeRequestBodyUsesMaxCompletionTokens() {
    let body = LLMModelDiscovery.makeOpenAIProbeRequestBody(modelID: "gpt-5")
    #expect(body["max_completion_tokens"] as? Int == 5)
  }

  @Test func modelProbeRequestBodyDoesNotUseDeprecatedMaxTokens() {
    let body = LLMModelDiscovery.makeOpenAIProbeRequestBody(modelID: "gpt-5")
    #expect(body["max_tokens"] == nil)
  }

  @Test func modelProbeRequestBodyDisablesProviderLogging() {
    let body = LLMModelDiscovery.makeOpenAIProbeRequestBody(modelID: "gpt-5")
    #expect(body["store"] as? Bool == false)
  }

  @Test func modelProbeRequestBodyEchoesModelID() {
    let body = LLMModelDiscovery.makeOpenAIProbeRequestBody(modelID: "gpt-5-mini")
    #expect(body["model"] as? String == "gpt-5-mini")
  }
}
