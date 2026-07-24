import EnviousWisprCore
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

  // MARK: - Truncation rejection (#1710)

  private func config() -> LLMProviderConfig {
    LLMProviderConfig(
      model: "gemini-2.5-flash", apiKeyKeychainId: "gemini-api-key",
      outputTokens: .providerDefault, temperature: 0, thinkingBudget: nil,
      reasoningEffort: nil)
  }

  private final class StatusBox: @unchecked Sendable {
    var status: String?
  }

  @Test("batch MAX_TOKENS rejects through the production body phase with error_after_200")
  func batchMaxTokensRejectsWithDiagnostics() {
    // batchBodyPhase is the SAME function polishBatch calls: extraction,
    // rejection, and failure-status recording in one authority.
    let data = responseJSON(text: "This got cut off mid", finishReason: "MAX_TOKENS")
    let box = StatusBox()
    #expect(throws: LLMError.classified(.outputTruncated)) {
      _ = try GeminiConnector.batchBodyPhase(
        data: data, statusCode: 200, config: config(),
        recordStatus: { box.status = $0 })
    }
    #expect(box.status?.hasPrefix("error_after_200") == true)
    #expect(box.status != "200")
  }

  @Test("batch STOP passes the production body phase without a status stamp")
  func batchStopPasses() throws {
    let data = responseJSON(text: "Complete.", finishReason: "STOP")
    let box = StatusBox()
    let extracted = try GeminiConnector.batchBodyPhase(
      data: data, statusCode: 200, config: config(),
      recordStatus: { box.status = $0 })
    #expect(extracted.text == "Complete.")
    #expect(box.status == nil)
  }

  private func sseStream(_ lines: [String]) -> AsyncStream<String> {
    AsyncStream { continuation in
      for line in lines { continuation.yield(line) }
      continuation.finish()
    }
  }

  @Test("streaming MAX_TOKENS rejects through the production body phase with error_after_200")
  func streamingMaxTokensRejectsWithDiagnostics() async {
    // streamBodyPhase is the SAME function polishStreaming calls: the real
    // accumulator, rejection, and failure-status recording in one authority.
    let lines = [
      #"data: {"candidates": [{"content": {"parts": [{"text": "This got "}]}}]}"#,
      "",
      #"data: {"candidates": [{"content": {"parts": [{"text": "cut off mid"}]}, "finishReason": "MAX_TOKENS"}]}"#,
    ]
    let box = StatusBox()
    await #expect(throws: LLMError.classified(.outputTruncated)) {
      _ = try await GeminiConnector.streamBodyPhase(
        lines: self.sseStream(lines), statusCode: 200, config: self.config(),
        onToken: { _ in }, recordStatus: { box.status = $0 })
    }
    #expect(box.status?.hasPrefix("error_after_200") == true)
    #expect(box.status != "200")
  }

  @Test("streaming STOP passes the production body phase and accumulates fully")
  func streamingStopPasses() async throws {
    let lines = [
      #"data: {"candidates": [{"content": {"parts": [{"text": "Complete."}]}, "finishReason": "STOP"}]}"#
    ]
    let box = StatusBox()
    let text = try await GeminiConnector.streamBodyPhase(
      lines: sseStream(lines), statusCode: 200, config: config(),
      onToken: { _ in }, recordStatus: { box.status = $0 })
    #expect(text == "Complete.")
    #expect(box.status == nil)
  }
}
