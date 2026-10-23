import EnviousWisprCore
import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// The model call behind each summary-capable provider and model (#3972 R44), with the window
/// it runs in and where it runs. Hosted providers and Ollama go through their own connectors
/// with the summary's envelope (they send system and user as given), with connector retries off
/// (`MeetingSummary` owns them) and the same thinking resolution polish uses. Apple Intelligence
/// gets a session of its own with the summary's instructions, because its connector builds the
/// dictation recipe and ignores custom instructions. EG-1 and S1-mini are cleanup models and
/// have no summary call, under their own providers or through Ollama.
public enum MeetingSummaryProviders {
  /// A summary-capable model, ready to call.
  public struct Prepared: Sendable {
    public let execution: MeetingSummary.Execution
    public let window: MeetingSummary.Window
    public let complete: MeetingSummary.Complete
  }

  /// Why no summary can be written now.
  public enum Unavailable: Error, Equatable {
    case noProvider
    case notForSummaries
    /// Ollama is not running or lacks the model, or Apple Intelligence is not available.
    case notReady
  }

  /// The window Ollama runs a summary call with, sent as `num_ctx`: polish sends none and keeps
  /// the daemon's default, which is smaller and silently drops the start of a longer prompt.
  static let ollamaContextTokens = 8_192

  /// Planning windows for hosted models, which publish no window in their APIs: the smallest
  /// window of the families named, and 8,000 for any other model the picker can list (the
  /// original GPT-4's), so an unknown model is planned small rather than overflowed.
  static func hostedContextTokens(_ provider: LLMProvider, model: String) -> Int {
    let id = model.lowercased()
    switch provider {
    case .gemini:
      // Every Gemini id the picker keeps has at least a 1M window (Gemma is filtered out).
      return id.hasPrefix("gemini-") ? 128_000 : 8_000
    case .claude:
      // Every Claude 3 and later model has a 200K window.
      return id.hasPrefix("claude-") ? 128_000 : 8_000
    case .openAI:
      let large = ["gpt-4o", "gpt-4.1", "gpt-4.5", "gpt-5", "gpt-6", "o1", "o3", "o4"]
      return large.contains { id.hasPrefix($0) } ? 128_000 : 8_000
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
      return 0
    }
  }

  /// Output room kept for a model that may think before it writes: reasoning counts against
  /// the answer on OpenAI and Gemini, and against `num_predict` on Ollama.
  static let thinkingReserveTokens = 8_000

  /// The call for `provider` and `model`, or why there is none. Ollama is asked first for its
  /// own facts about the model (where it runs, whether it thinks), as polish does per attempt.
  public static func prepare(
    provider: LLMProvider, model: String, keychain: KeychainManager,
    ollamaReadiness: @Sendable (String) async -> OllamaReadiness = {
      await OllamaConnector().preflightReadiness(model: $0)
    },
    ollamaExecutor: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
  ) async -> Result<Prepared, Unavailable> {
    switch MeetingSummary.capability(provider, model: model, ollamaModelIsRemote: nil) {
    case .noProvider: return .failure(.noProvider)
    case .notForSummaries: return .failure(.notForSummaries)
    case .supported: break
    }
    let capabilities = provider.modelCapabilities(model: model)
    switch provider {
    case .openAI, .gemini:
      let thinking = capabilities.thinkingControl.resolved
      // No cap, like polish: a cap would also bound reasoning and cut the visible answer.
      let config = LLMProviderConfig(
        model: model,
        apiKeyKeychainId: provider == .openAI
          ? KeychainManager.openAIKeyID : KeychainManager.geminiKeyID,
        outputTokens: .providerDefault, temperature: 0, thinking: thinking, maxRetries: 0)
      let connector: any TranscriptPolisher =
        provider == .openAI
        ? OpenAIConnector(keychainManager: keychain) : GeminiConnector(keychainManager: keychain)
      return .success(
        Prepared(
          execution: .hosted,
          window: MeetingSummary.Window(
            contextTokens: hostedContextTokens(provider, model: model),
            outputReserveTokens: MeetingSummary.outputTokens + thinkingReserveTokens),
          complete: envelope(connector, config)))
    case .claude:
      // Claude requires `max_tokens`; the connector builds its own thinking part per model
      // (`claudeRequestShape`), so the cap is the polish ceiling that covers it.
      let config = LLMProviderConfig(
        model: model, apiKeyKeychainId: KeychainManager.claudeKeyID,
        outputTokens: .capped(LLMConstants.claudeMaxOutputTokens), temperature: 0,
        thinking: nil, maxRetries: 0)
      return .success(
        Prepared(
          execution: .hosted,
          window: MeetingSummary.Window(
            contextTokens: hostedContextTokens(.claude, model: model),
            outputReserveTokens: LLMConstants.claudeMaxOutputTokens),
          complete: envelope(ClaudeConnector(keychainManager: keychain), config)))
    case .ollama:
      guard case .ready(let facts) = await ollamaReadiness(model) else {
        return .failure(.notReady)
      }
      guard
        case .supported(let execution) = MeetingSummary.capability(
          .ollama, model: model, ollamaModelIsRemote: facts.isRemote)
      else { return .failure(.notForSummaries) }
      // Only a reported non-thinking model is planned without thinking room; a thinking or
      // unknown one gets polish's thinking floor on top, as polish's own floor rule does.
      let output =
        MeetingSummary.outputTokens
        + (facts.thinks == false ? 0 : LLMConstants.ollamaThinkingMaxTokens)
      let config = LLMProviderConfig(
        model: model, apiKeyKeychainId: nil, outputTokens: .capped(output), temperature: 0,
        thinking: .ollama(thinks: facts.thinks), maxRetries: 0,
        contextTokens: ollamaContextTokens)
      let connector =
        ollamaExecutor.map {
          OllamaConnector(networkExecutor: $0, telemetrySink: keychain.telemetrySink)
        } ?? OllamaConnector(telemetrySink: keychain.telemetrySink)
      return .success(
        Prepared(
          execution: execution,
          window: MeetingSummary.Window(
            contextTokens: ollamaContextTokens, outputReserveTokens: output),
          complete: envelope(connector, config)))
    case .appleIntelligence:
      guard let context = appleContextTokens() else { return .failure(.notReady) }
      return .success(
        Prepared(
          execution: .local,
          window: MeetingSummary.Window(
            contextTokens: context, outputReserveTokens: MeetingSummary.outputTokens),
          complete: { instructions, prompt in
            try await apple(instructions: instructions, prompt: prompt)
          }))
    case .egOne, .s1Mini, .none:
      return .failure(.notForSummaries)
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
        do {
          let response = try await session.respond(
            to: prompt,
            options: GenerationOptions(
              sampling: .greedy, maximumResponseTokens: MeetingSummary.outputTokens))
          return response.content
        } catch let error as LanguageModelSession.GenerationError {
          // The estimate is meant to keep every call inside the window; if the model still
          // says otherwise, the meeting is too long for it, which a retry cannot change.
          if case .exceededContextWindowSize = error { throw MeetingSummary.Failure.tooLong }
          throw error
        }
      }
    #endif
    throw LLMError.frameworkUnavailable("apple_intelligence_unavailable")
  }
}
