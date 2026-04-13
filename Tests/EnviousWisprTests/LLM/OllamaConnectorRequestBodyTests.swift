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
}
