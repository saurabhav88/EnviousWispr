import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// Contract tests verifying PromptEnvelope -> correct API payload mapping per connector.
/// These test the envelope extraction logic, not the actual API calls.
@Suite("Connector Envelope Contracts")
struct ConnectorContractTests {

  // MARK: - PromptEnvelope.asSingleTurn()

  @Test("asSingleTurn succeeds for system + user pair")
  func singleTurnBasic() {
    let envelope = PromptEnvelope(messages: [
      PromptMessage(role: .system, content: "System prompt"),
      PromptMessage(role: .user, content: "User text"),
    ])
    let pair = envelope.asSingleTurn()
    #expect(pair != nil)
    #expect(pair?.system == "System prompt")
    #expect(pair?.user == "User text")
  }

  @Test("asSingleTurn returns nil for few-shot envelope")
  func singleTurnFewShot() {
    let envelope = PromptEnvelope(messages: [
      PromptMessage(role: .system, content: "System"),
      PromptMessage(role: .user, content: "Input 1"),
      PromptMessage(role: .assistant, content: "Output 1"),
      PromptMessage(role: .user, content: "Input 2"),
    ])
    #expect(envelope.asSingleTurn() == nil)
  }

  @Test("asSingleTurn returns nil for multiple user messages")
  func singleTurnMultipleUsers() {
    let envelope = PromptEnvelope(messages: [
      PromptMessage(role: .system, content: "System"),
      PromptMessage(role: .user, content: "User 1"),
      PromptMessage(role: .user, content: "User 2"),
    ])
    #expect(envelope.asSingleTurn() == nil)
  }

  @Test("asSingleTurn handles user-only (no system)")
  func singleTurnNoSystem() {
    let envelope = PromptEnvelope(messages: [
      PromptMessage(role: .user, content: "Just user")
    ])
    let pair = envelope.asSingleTurn()
    #expect(pair != nil)
    #expect(pair?.system == nil)
    #expect(pair?.user == "Just user")
  }

  // MARK: - OpenAI envelope contract

  // MARK: - Gemini envelope contract

  @Test("Gemini plan is a single-turn fixed v6 prompt with a plain user message")
  func geminiSingleTurn() {
    let input = PromptBuildInput(
      transcript: "test text",
      provider: .gemini,
      modelID: "gemini-2.5-flash",
      appName: "Slack",
      language: nil,
      polishVocabulary: PolishVocabulary(terms: [], generation: 0)
    )
    let plan = DefaultPromptPlanner().plan(input: input)
    let pair = plan.envelope.asSingleTurn()
    #expect(pair != nil)
    // #1255: Gemini now uses the same fixed cloud prompt — plain user message, no sandwich.
    #expect(pair?.user == "Transcript to clean:\n\ntest text")
    #expect(pair?.user.contains("<transcript>") == false)
    #expect(pair?.user.contains("test text") == true)
    #expect(pair?.system?.contains("You are the writing assistant inside a dictation app") == true)
    #expect(pair?.system?.contains("<transcript>") == false)
  }

  // MARK: - Claude envelope contract (#158)

  // MARK: - Ollama/Gemma envelope contract
}
