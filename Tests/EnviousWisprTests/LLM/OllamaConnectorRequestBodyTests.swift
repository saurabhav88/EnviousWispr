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

  // MARK: - evictModel fire-and-forget guard (#295, hardened #901)

  /// Empty model names are a no-op — the guard must return before any network
  /// call. The old test only bounded wall-clock (< 0.5s) against a non-routable
  /// host, which a deleted `!modelName.isEmpty` guard still satisfied via fast
  /// ECONNREFUSED. This counts requests instead: empty name => zero calls.
  @Test("empty model name evicts without any network call")
  func evictModelWithEmptyNameMakesNoRequest() async {
    let counter = RequestCounter()
    let connector = OllamaConnector(networkExecutor: { _ in
      await counter.bump()
      throw URLError(.cannotConnectToHost)  // evict is fire-and-forget; the throw is ignored
    })
    await connector.evictModel("")
    #expect(await counter.count == 0)  // guard active: the network was never reached
  }

  /// The other side of the routing flip (`matcher-set-adversarial-tests`): a
  /// non-empty name must reach the network exactly once. Pins the guard from
  /// both sides so deleting it is caught regardless of which case regresses.
  @Test("non-empty model name evicts via exactly one network call")
  func evictModelWithNonEmptyNameMakesOneRequest() async {
    let counter = RequestCounter()
    let connector = OllamaConnector(networkExecutor: { _ in
      await counter.bump()
      throw URLError(.cannotConnectToHost)  // evict ignores the throw
    })
    await connector.evictModel("gemma4:latest")
    #expect(await counter.count == 1)
  }

  /// The polish call site must also route through the injected executor and
  /// surface a transport failure (not silently swallow it). The evict-only count
  /// tests can't catch a bad polish reroute.
  @Test("polish surfaces a transport failure through the injected executor")
  func polishSurfacesExecutorError() async {
    let connector = OllamaConnector(networkExecutor: { _ in
      throw URLError(.notConnectedToInternet)  // maps to providerUnavailable, fail-fast
    })
    let config = LLMProviderConfig(
      model: "gemma4:latest",
      apiKeyKeychainId: nil,
      maxTokens: 128,
      temperature: 0.3,
      thinkingBudget: nil,
      reasoningEffort: nil
    )
    await #expect(throws: LLMError.self) {
      _ = try await connector.polish(
        text: "hello",
        instructions: PolishInstructions(systemPrompt: "sys"),
        config: config,
        onToken: nil
      )
    }
  }
}

/// Counts how many times the injected network executor is invoked. An actor so
/// the `@Sendable` executor closure can mutate it from any concurrency domain.
private actor RequestCounter {
  private(set) var count = 0
  func bump() { count += 1 }
}
