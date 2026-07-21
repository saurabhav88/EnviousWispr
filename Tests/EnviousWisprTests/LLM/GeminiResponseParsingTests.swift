import Foundation
import Testing

@testable import EnviousWisprLLM

/// #1710 Gap 2: `extractBatchResponseText` is a pure success-body parser
/// (mirroring `ClaudeConnector.extractResponseText`, Codex r6), extracted
/// out of `GeminiConnector.polishBatch` specifically so this edge case is
/// unit-testable directly against `Data` literals — neither Gemini nor
/// Claude has an injectable transport seam (only `OpenAIConnector` does; see
/// `ClaudeConnectorTests.swift`).
@Suite("Gemini batch response parsing")
struct GeminiResponseParsingTests {

  private func responseJSON(
    text: String, finishReason: String? = nil, thought: Bool = false
  ) -> Data {
    var part: [String: Any] = ["text": text]
    if thought { part["thought"] = true }
    var candidate: [String: Any] = ["content": ["parts": [part]]]
    if let finishReason { candidate["finishReason"] = finishReason }
    let payload: [String: Any] = ["candidates": [candidate]]
    return try! JSONSerialization.data(withJSONObject: payload)
  }

  @Test func extractBatchResponseTextReturnsCleanText() throws {
    let data = responseJSON(text: "Cleaned up dictation.")
    let result = try GeminiConnector.extractBatchResponseText(from: data)
    #expect(result.text == "Cleaned up dictation.")
    #expect(result.finishReason == nil)
  }

  @Test func extractBatchResponseTextFlagsMaxTokensTruncation() throws {
    let data = responseJSON(text: "This got cut off mid", finishReason: "MAX_TOKENS")
    let result = try GeminiConnector.extractBatchResponseText(from: data)
    #expect(result.text == "This got cut off mid")
    #expect(result.finishReason == "MAX_TOKENS")
  }

  @Test func extractBatchResponseTextThrowsOnWhitespaceOnlyContent() {
    // The raw joined text is non-empty ("   \n  "), so a check against the
    // UNTRIMMED string would incorrectly treat this as success (#1710 Gap 2
    // — the same shape the Codex r6 Claude fix targeted).
    let data = responseJSON(text: "   \n  ")
    #expect(throws: LLMError.self) {
      try GeminiConnector.extractBatchResponseText(from: data)
    }
  }

  @Test func extractBatchResponseTextThrowsOnAllThoughtResponse() {
    let data = responseJSON(text: "internal reasoning only", thought: true)
    #expect(throws: LLMError.self) {
      try GeminiConnector.extractBatchResponseText(from: data)
    }
  }

  @Test func extractBatchResponseTextThrowsOnMissingCandidates() {
    let data = try! JSONSerialization.data(withJSONObject: ["promptFeedback": [:]])
    #expect(throws: LLMError.self) {
      try GeminiConnector.extractBatchResponseText(from: data)
    }
  }
}
