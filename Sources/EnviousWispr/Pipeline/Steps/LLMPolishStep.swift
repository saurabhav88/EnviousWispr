import Foundation
import EnviousWisprCore

/// Polishes transcribed text using an LLM provider.
@MainActor
final class LLMPolishStep: TextProcessingStep {
    let name = "LLM Polish"

    var llmProvider: LLMProvider = .none
    var llmModel: String = "gpt-4o-mini"
    var polishInstructions: PolishInstructions = .default
    var useExtendedThinking: Bool = false

    /// Called before LLM processing starts (pipeline uses this to set .polishing state).
    var onWillProcess: (() -> Void)?

    /// Streaming token callback — invoked with each text fragment as it arrives from the LLM.
    var onToken: (@Sendable (String) -> Void)?

    private let keychainManager: KeychainManager

    var isEnabled: Bool {
        llmProvider != .none
    }

    init(keychainManager: KeychainManager) {
        self.keychainManager = keychainManager
    }

    /// Minimum word count to send to the LLM. Transcripts at or below this
    /// threshold are passed through verbatim — LLMs hallucinate on ultra-short
    /// input (e.g., "Yeah" → a full essay). See ew-zr4.
    private static let minWordsForPolish = 3

    func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
        onWillProcess?()

        // Short-circuit: ultra-short transcripts get passed through verbatim.
        // LLMs treat 1-3 word inputs as prompts to respond to, not text to clean.
        let wordCount = context.text.split(whereSeparator: \.isWhitespace).count
        if wordCount <= Self.minWordsForPolish {
            Task { await AppLogger.shared.log(
                "LLM polish skipped: transcript too short (\(wordCount) words, minimum \(Self.minWordsForPolish + 1))",
                level: .info, category: "LLM"
            ) }
            var ctx = context
            ctx.polishedText = context.text
            return ctx
        }

        Task { await AppLogger.shared.log(
            "LLM polish requested: provider=\(llmProvider.rawValue), model=\(llmModel)",
            level: .verbose, category: "LLM"
        ) }

        let polisher: any TranscriptPolisher = switch llmProvider {
        case .openAI: OpenAIConnector(keychainManager: keychainManager)
        case .gemini: GeminiConnector(keychainManager: keychainManager)
        case .ollama: OllamaConnector()
        case .appleIntelligence: AppleIntelligenceConnector()
        case .none: throw LLMError.providerUnavailable
        }

        let keychainId: String? = switch llmProvider {
        case .openAI:  KeychainManager.openAIKeyID
        case .gemini:  KeychainManager.geminiKeyID
        default:       nil
        }

        let maxTokens = llmProvider == .ollama ? LLMConstants.ollamaMaxTokens : LLMConstants.defaultMaxTokens
        let (thinkingBudget, reasoningEffort) = resolveThinkingConfig()

        let config = LLMProviderConfig(
            model: llmModel,
            apiKeyKeychainId: keychainId,
            maxTokens: maxTokens,
            temperature: 0.3,
            thinkingBudget: thinkingBudget,
            reasoningEffort: reasoningEffort
        )

        // Enrich instructions with pipeline context (language, etc.)
        // then resolve ${transcript} placeholder if present.
        let enriched = enrichedInstructions(polishInstructions, context: context)
        var resolvedInstructions = enriched
        var userText = context.text
        if enriched.systemPrompt.contains("${transcript}") {
            let resolved = enriched.systemPrompt.replacingOccurrences(
                of: "${transcript}", with: context.text
            )
            resolvedInstructions = PolishInstructions(
                systemPrompt: resolved
            )
            userText = ""
        }

        let llmStart = CFAbsoluteTimeGetCurrent()
        let result = try await polisher.polish(
            text: userText,
            instructions: resolvedInstructions,
            config: config,
            onToken: onToken
        )
        let llmEnd = CFAbsoluteTimeGetCurrent()

        Task { await AppLogger.shared.log(
            "LLM polish complete: \(result.polishedText.count) chars in \(String(format: "%.3f", llmEnd - llmStart))s " +
            "(provider=\(llmProvider.rawValue), model=\(llmModel))",
            level: .info, category: "PipelineTiming"
        ) }

        var ctx = context
        ctx.polishedText = result.polishedText
        ctx.llmProvider = llmProvider.rawValue
        ctx.llmModel = llmModel
        return ctx
    }

    // MARK: - Context-Aware Prompt Enrichment

    /// Enrich polish instructions with pipeline context before sending to the LLM.
    /// This is the single place to add context-aware prompt modifications.
    /// Language handling lives here (not in PolishInstructions or TranscriptPolisher)
    /// because it's pipeline metadata, not user-facing prompt configuration.
    private func enrichedInstructions(
        _ base: PolishInstructions,
        context: TextProcessingContext
    ) -> PolishInstructions {
        var systemPrompt = base.systemPrompt

        // Add language context for non-English transcripts.
        // Without this, the LLM assumes English and corrupts non-English text.
        if let language = context.language,
           !language.isEmpty,
           !language.lowercased().hasPrefix("en") {
            let languageName = Locale.current.localizedString(forLanguageCode: language) ?? language
            systemPrompt = """
                LANGUAGE: This transcript is in \(languageName) (\(language)). \
                Polish it in \(languageName) — do NOT translate to English. \
                Apply the same rules below but in the transcript's language.

                \(systemPrompt)
                """
        }

        // Guard against hallucination on short transcripts (4-10 words).
        // The hard cutoff in process() catches ≤3 words; this prompt
        // reinforcement catches the gray zone where the LLM might still
        // treat a short phrase as a prompt to respond to.
        let wordCount = context.text.split(whereSeparator: \.isWhitespace).count
        if wordCount <= 10 {
            systemPrompt += """

                IMPORTANT: If the transcript is very short (just a few words or a single sentence), \
                return it as-is with only minimal punctuation/capitalization fixes. \
                Do NOT expand, elaborate, or generate new content. Short inputs are intentional.
                """
        }

        return PolishInstructions(systemPrompt: systemPrompt)
    }

    /// Resolve thinking/reasoning config based on provider, model, and user toggle.
    private func resolveThinkingConfig() -> (thinkingBudget: Int?, reasoningEffort: String?) {
        switch llmProvider {
        case .gemini:
            let isThinkingModel = llmModel.hasPrefix("gemini-2.5") || llmModel.hasPrefix("gemini-3")
            guard isThinkingModel else { return (nil, nil) }
            return (useExtendedThinking ? LLMConstants.defaultThinkingBudget : 0, nil)
        case .openAI:
            let isReasoningModel = llmModel.hasPrefix("o1") || llmModel.hasPrefix("o3") || llmModel.hasPrefix("o4")
            guard isReasoningModel else { return (nil, nil) }
            return (nil, useExtendedThinking ? "medium" : "low")
        case .ollama, .appleIntelligence, .none:
            return (nil, nil)
        }
    }
}
