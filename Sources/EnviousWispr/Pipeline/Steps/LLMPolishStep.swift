import Foundation

/// Polishes transcribed text using an LLM provider.
@MainActor
final class LLMPolishStep: TextProcessingStep {
    let name = "LLM Polish"

    var llmProvider: LLMProvider = .none
    var llmModel: String = "gpt-4o-mini"
    var polishInstructions: PolishInstructions = .default

    /// Called before LLM processing starts (pipeline uses this to set .polishing state).
    var onWillProcess: (() -> Void)?

    private let keychainManager: KeychainManager

    var isEnabled: Bool {
        llmProvider != .none
    }

    init(keychainManager: KeychainManager) {
        self.keychainManager = keychainManager
    }

    func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
        onWillProcess?()

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

        let config = LLMProviderConfig(
            provider: llmProvider,
            model: llmModel,
            apiKeyKeychainId: keychainId,
            maxTokens: maxTokens,
            temperature: 0.3
        )

        // Resolve ${transcript} placeholder if present
        var resolvedInstructions = polishInstructions
        var userText = context.text
        if polishInstructions.systemPrompt.contains("${transcript}") {
            let resolved = polishInstructions.systemPrompt.replacingOccurrences(
                of: "${transcript}", with: context.text
            )
            resolvedInstructions = PolishInstructions(
                systemPrompt: resolved,
                removeFillerWords: polishInstructions.removeFillerWords,
                fixGrammar: polishInstructions.fixGrammar,
                fixPunctuation: polishInstructions.fixPunctuation
            )
            userText = ""
        }

        let result = try await polisher.polish(
            text: userText,
            instructions: resolvedInstructions,
            config: config
        )

        Task { await AppLogger.shared.log(
            "LLM polish complete: \(result.polishedText.count) chars",
            level: .verbose, category: "LLM"
        ) }

        var ctx = context
        ctx.polishedText = result.polishedText
        ctx.llmProvider = llmProvider.rawValue
        ctx.llmModel = llmModel
        return ctx
    }
}
