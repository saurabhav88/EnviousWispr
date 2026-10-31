import EnviousWisprCore
import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// The model call behind each summary-capable provider and model (#3972 R44), with the window
/// it runs in and where it runs. Hosted providers and Ollama go through their own connectors
/// with the summary's envelope (they send system and user as given), with connector retries off
/// (`MeetingSummary` owns them), the same thinking resolution polish uses, and an output cap
/// equal to the reserve the plan keeps. Apple Intelligence gets a session of its own with the
/// summary's instructions, because its connector builds the dictation recipe and ignores custom
/// instructions. EG-1 and S1-mini are cleanup models and have no summary call, under their own
/// providers or through Ollama.
///
/// An answer cut short is never accepted: the hosted connectors reject a length stop
/// themselves, Ollama's is refused here (`LLMResult.stoppedEarly`), and Apple Intelligence runs
/// without a response cap (a cap there truncates silently), so an answer that outgrows its
/// window is the framework's reported overflow.
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
    /// The Ollama app is older than 0.12.6, which cannot be asked to report a prompt that does
    /// not fit instead of cutting it.
    case ollamaTooOld
  }

  /// The window Ollama runs a summary call with, sent as `num_ctx` with `truncate` and `shift`
  /// off, so the daemon reports a prompt or answer that does not fit. Polish sends none of these
  /// and keeps the daemon's default window, which silently drops the start of a longer prompt.
  static let ollamaContextTokens = 8_192

  /// Planning windows for hosted models, which publish no window in their APIs. Each named
  /// family's smallest published window is at least 128,000 tokens (Gemini 1.5 and later:
  /// 1,048,576; Claude 3 and later: 200,000; OpenAI GPT-4o, GPT-4.5 and o1-mini: 128,000;
  /// GPT-4.1: 1,047,576; GPT-5: 400,000; o1, o3, o4-mini: 200,000). Any other model the picker
  /// can list (the original GPT-4, GPT-3.5, Gemini 1.0) is planned at 8,000, the smallest of
  /// those, so an unknown model is planned small rather than overflowed. A plan that does not
  /// fit is refused before any call (`Failure.windowTooSmall`); a model whose real window is
  /// smaller still reports the overflow, and the summary re-plans with the byte count.
  static func hostedContextTokens(_ provider: LLMProvider, model: String) -> Int {
    let id = model.lowercased()
    switch provider {
    case .gemini:
      let old = id.hasPrefix("gemini-1.0") || id == "gemini-pro"
      return id.hasPrefix("gemini-") && !old ? 128_000 : 8_000
    case .claude:
      return id.hasPrefix("claude-") && !id.hasPrefix("claude-2") && !id.hasPrefix("claude-instant")
        ? 128_000 : 8_000
    case .openAI:
      let large = ["gpt-4o", "gpt-4.1", "gpt-4.5", "gpt-5", "gpt-6", "o1", "o3", "o4"]
      return large.contains { id.hasPrefix($0) } ? 128_000 : 8_000
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
      return 0
    }
  }

  /// Output room for a model that may think before it writes, on top of the visible answer:
  /// reasoning counts against the output cap on OpenAI and Gemini, and against `num_predict` on
  /// Ollama.
  static let thinkingReserveTokens = 8_000

  /// The output cap, sent and reserved, for a hosted model: the visible answer, plus thinking
  /// room where the model may think (an OpenAI reasoning model, any Gemini model, since Gemini
  /// 2.5 and later think by default), or Claude's polish ceiling, which its connector's own
  /// thinking part fits inside.
  static func hostedOutputTokens(_ provider: LLMProvider, model: String) -> Int {
    let capabilities = provider.modelCapabilities(model: model)
    switch provider {
    case .openAI:
      // `temperaturePolicy` is `.omit` exactly for the reasoning family.
      return capabilities.temperaturePolicy == .omit
        ? MeetingSummary.outputTokens + thinkingReserveTokens : MeetingSummary.outputTokens
    case .gemini: return MeetingSummary.outputTokens + thinkingReserveTokens
    case .claude: return LLMConstants.claudeMaxOutputTokens
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return 0
    }
  }

  /// A hosted summary request: the output cap equal to the reserve, connector retries off, and
  /// the thinking value polish would send (Claude's thinking part comes from its connector,
  /// `claudeRequestShape`).
  static func hostedConfig(_ provider: LLMProvider, model: String, keyID: String)
    -> LLMProviderConfig
  {
    let thinking =
      provider == .claude ? nil : provider.modelCapabilities(model: model).thinkingControl.resolved
    return LLMProviderConfig(
      model: model, apiKeyKeychainId: keyID,
      outputTokens: .capped(hostedOutputTokens(provider, model: model)), temperature: 0,
      thinking: thinking, maxRetries: 0)
  }

  /// The call for `provider` and `model`, or why there is none. Ollama is asked first for its
  /// own facts about the model (where it runs, whether it thinks), as polish does per attempt,
  /// and for its version: one that cannot be told not to cut a prompt is refused.
  public static func prepare(
    provider: LLMProvider, model: String, keychain: KeychainManager,
    ollamaReadiness: @Sendable (String) async -> OllamaReadiness = {
      await OllamaConnector().preflightReadiness(model: $0)
    },
    ollamaVersion: @Sendable () async -> String? = { await OllamaConnector().serverVersion() },
    ollamaExecutor: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
  ) async -> Result<Prepared, Unavailable> {
    switch MeetingSummary.capability(provider, model: model, ollamaModelIsRemote: nil) {
    case .noProvider: return .failure(.noProvider)
    case .notForSummaries: return .failure(.notForSummaries)
    case .supported: break
    }
    switch provider {
    case .openAI, .gemini, .claude:
      let output = hostedOutputTokens(provider, model: model)
      let (keyID, connector): (String, any TranscriptPolisher) =
        switch provider {
        case .openAI: (KeychainManager.openAIKeyID, OpenAIConnector(keychainManager: keychain))
        case .gemini: (KeychainManager.geminiKeyID, GeminiConnector(keychainManager: keychain))
        default: (KeychainManager.claudeKeyID, ClaudeConnector(keychainManager: keychain))
        }
      let config = hostedConfig(provider, model: model, keyID: keyID)
      return .success(
        Prepared(
          execution: .hosted,
          window: MeetingSummary.Window(
            contextTokens: hostedContextTokens(provider, model: model),
            outputReserveTokens: output),
          complete: envelope(connector, config)))
    case .ollama:
      guard case .ready(let facts) = await ollamaReadiness(model) else {
        return .failure(.notReady)
      }
      guard OllamaConnector.supportsNoTruncation(version: await ollamaVersion()) else {
        return .failure(.ollamaTooOld)
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

  /// The call through a connector. An answer the connector marks as stopped early is refused.
  static func envelope(_ connector: any TranscriptPolisher, _ config: LLMProviderConfig)
    -> MeetingSummary.Complete
  {
    { instructions, prompt in
      let result = try await connector.polish(
        envelope: PromptEnvelope(messages: [
          PromptMessage(role: .system, content: instructions),
          PromptMessage(role: .user, content: prompt),
        ]), config: config, onToken: nil)
      guard !result.stoppedEarly else { throw MeetingSummary.Failure.truncated }
      // The source here is the summary request, not a dictated reply. Preserve
      // the connector's prior added-chatter cleanup at this direct consumer.
      return result.polishedText.strippingLLMPreamble(dictation: prompt)
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
          // No `maximumResponseTokens`: it truncates the answer without saying so.
          let response = try await session.respond(
            to: prompt, options: GenerationOptions(sampling: .greedy))
          return response.content
        } catch let error as LanguageModelSession.GenerationError {
          if case .exceededContextWindowSize = error { throw MeetingSummary.ContextExceeded() }
          throw error
        }
      }
    #endif
    throw LLMError.frameworkUnavailable("apple_intelligence_unavailable")
  }
}
