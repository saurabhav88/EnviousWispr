import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("OllamaConnector request body")
struct OllamaConnectorRequestBodyTests {

  private func makeBody(temperature: Double = 0.3, maxTokens: Int = 512) -> [String: Any] {
    OllamaConnector.makeRequestBody(
      model: "gemma4:latest",
      messages: [
        ["role": "system", "content": "sys"],
        ["role": "user", "content": "hello"],
      ],
      maxTokens: maxTokens,
      temperature: temperature
    )
  }

  /// Primary regression guard for #272. Passing `think: false` at the top level
  /// is silently ignored by gemma4:latest and causes chain-of-thought to leak
  /// into `message.content` (5-13× expansion). Omitting the key uses Ollama's
  /// documented default (thinking OFF) and restores polish behavior.
  @Test func requestBodyDoesNotIncludeThinkKey() {
    let body = makeBody()
    #expect(body["think"] == nil)
  }

  @Test func requestBodyDisablesStreaming() {
    let body = makeBody()
    #expect(body["stream"] as? Bool == false)
  }

  @Test func requestBodyPassesModelAndMessages() {
    let body = makeBody()
    #expect(body["model"] as? String == "gemma4:latest")
    let messages = body["messages"] as? [[String: String]]
    #expect(messages?.count == 2)
    #expect(messages?.first?["role"] == "system")
  }

  @Test func requestBodyMapsOptions() {
    let body = makeBody(temperature: 0.42, maxTokens: 777)
    let options = body["options"] as? [String: Any]
    #expect(options?["num_predict"] as? Int == 777)
    #expect(options?["temperature"] as? Double == 0.42)
  }

  // MARK: - Eviction body (#295)

  @Test func evictRequestBodyCarriesModel() {
    let body = OllamaConnector.makeEvictRequestBody(model: "gemma4:latest")
    #expect(body["model"] as? String == "gemma4:latest")
  }

  /// `keep_alive: 0` is the documented Ollama unload trigger. Must be an
  /// integer 0, not the string "0" — Ollama parses these differently.
  @Test func evictRequestBodyUsesKeepAliveZero() {
    let body = OllamaConnector.makeEvictRequestBody(model: "gemma4:latest")
    #expect(body["keep_alive"] as? Int == 0)
  }

  /// Empty prompt is included explicitly. Some Ollama builds 400 on missing
  /// `prompt` key even for unload calls, so we always emit it.
  @Test func evictRequestBodyIncludesEmptyPrompt() {
    let body = OllamaConnector.makeEvictRequestBody(model: "gemma4:latest")
    #expect(body["prompt"] as? String == "")
  }

  /// Nothing else should be in the unload body — no streaming, no options,
  /// no messages. Keeps the call as narrow as possible.
  @Test func evictRequestBodyHasOnlyExpectedKeys() {
    let body = OllamaConnector.makeEvictRequestBody(model: "gemma4:latest")
    let keys = Set(body.keys)
    #expect(keys == Set(["model", "prompt", "keep_alive"]))
  }

  // MARK: - effectiveOllamaModel classifier (#295)

  @Test func effectiveOllamaModelReturnsModelWhenProviderIsOllama() {
    #expect(
      OllamaConnector.effectiveOllamaModel(provider: .ollama, model: "gemma4:latest")
        == "gemma4:latest"
    )
  }

  @Test func effectiveOllamaModelReturnsNilWhenProviderIsNotOllama() {
    #expect(
      OllamaConnector.effectiveOllamaModel(provider: .openAI, model: "gemma4:latest") == nil
    )
    #expect(
      OllamaConnector.effectiveOllamaModel(provider: .gemini, model: "gemma4:latest") == nil
    )
    #expect(
      OllamaConnector.effectiveOllamaModel(
        provider: .appleIntelligence, model: "apple-intelligence"
      ) == nil
    )
    #expect(
      OllamaConnector.effectiveOllamaModel(provider: .none, model: "") == nil
    )
  }

  @Test func effectiveOllamaModelReturnsNilWhenModelIsEmpty() {
    #expect(OllamaConnector.effectiveOllamaModel(provider: .ollama, model: "") == nil)
  }

  // MARK: - evictModel fire-and-forget guard (#295)

  /// Empty model names are a no-op — the method must return immediately
  /// without hitting the network. Regression guard for callers that pass
  /// the stored model field without first checking `isEmpty`.
  @Test func evictModelWithEmptyNameIsNoOp() async {
    // Pointed at a non-routable address so any accidental network
    // call would time out rather than succeed; the test completes
    // in well under the 3s connector timeout because the guard
    // short-circuits before `URLSession.data(for:)` is invoked.
    let connector = OllamaConnector(baseURL: "http://127.0.0.1:1")
    let start = Date()
    await connector.evictModel("")
    #expect(Date().timeIntervalSince(start) < 0.5)
  }
}
