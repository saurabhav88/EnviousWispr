import EnviousWisprCore
import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// The model call behind each summary-capable provider (#3972 R44). Hosted providers and
/// Ollama go through their own connectors with the summary's envelope (they send system and
/// user as given); Apple Intelligence gets a session of its own with the summary's instructions,
/// because its connector builds the dictation recipe and ignores custom instructions. EG-1 and
/// S1-mini are cleanup models and have no summary call (`MeetingSummary.notForSummaries`).
public enum MeetingSummaryProviders {
  /// The call for `provider`, or nil when it cannot write summaries.
  public static func complete(
    provider: LLMProvider, model: String, keychain: KeychainManager
  ) -> MeetingSummary.Complete? {
    let capped = OutputTokenPolicy.capped(MeetingSummary.outputTokens)
    switch provider {
    case .openAI:
      return envelope(
        OpenAIConnector(keychainManager: keychain),
        LLMProviderConfig(
          model: model, apiKeyKeychainId: KeychainManager.openAIKeyID, outputTokens: capped,
          temperature: 0, thinking: nil))
    case .gemini:
      return envelope(
        GeminiConnector(keychainManager: keychain),
        LLMProviderConfig(
          model: model, apiKeyKeychainId: KeychainManager.geminiKeyID, outputTokens: capped,
          temperature: 0, thinking: nil))
    case .claude:
      return envelope(
        ClaudeConnector(keychainManager: keychain),
        LLMProviderConfig(
          model: model, apiKeyKeychainId: KeychainManager.claudeKeyID, outputTokens: capped,
          temperature: 0, thinking: nil))
    case .ollama:
      return envelope(
        OllamaConnector(telemetrySink: keychain.telemetrySink),
        LLMProviderConfig(
          model: model, apiKeyKeychainId: nil, outputTokens: capped, temperature: 0,
          thinking: nil))
    case .appleIntelligence:
      return { instructions, prompt in try await apple(instructions: instructions, prompt: prompt) }
    case .egOne, .s1Mini, .none:
      return nil
    }
  }

  /// Apple Intelligence's live context window in tokens, or nil where it is unavailable.
  public static func appleContextTokens() -> Int? {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard case .available = model.availability else { return nil }
        return model.contextSize
      }
    #endif
    return nil
  }

  private static func envelope(_ connector: any TranscriptPolisher, _ config: LLMProviderConfig)
    -> MeetingSummary.Complete
  {
    { instructions, prompt in
      let result = try await connector.polish(
        envelope: PromptEnvelope(messages: [
          PromptMessage(role: .system, content: instructions),
          PromptMessage(role: .user, content: prompt),
        ]), config: config, onToken: nil)
      return result.polishedText
    }
  }

  private static func apple(instructions: String, prompt: String) async throws -> String {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard case .available = model.availability else {
          throw LLMError.frameworkUnavailable("apple_intelligence_unavailable")
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(
          to: prompt,
          options: GenerationOptions(
            sampling: .greedy, maximumResponseTokens: MeetingSummary.outputTokens))
        return response.content
      }
    #endif
    throw LLMError.frameworkUnavailable("apple_intelligence_unavailable")
  }
}
