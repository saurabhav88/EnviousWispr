import EnviousWisprCore

/// Default implementation of PromptPlanning.
/// Analyzes transcript, selects the appropriate builder, and produces a PolishPlan.
/// Never throws. Bad/missing inputs degrade gracefully.
public struct DefaultPromptPlanner: PromptPlanning {
    public init() {}

    public func plan(input: PromptBuildInput) -> PolishPlan {
        // legacyTemplate mode defaults to .message for validator thresholds
        let mode: PolishMode
        if input.customPromptMode == .legacyTemplate {
            mode = .message
        } else {
            mode = TranscriptAnalyzer.analyzeMode(
                transcript: input.transcript,
                appName: input.appName
            )
        }

        let builder = Self.builder(for: input.provider, modelID: input.modelID)
        let envelope = builder.build(input: input, mode: mode)
        return PolishPlan(mode: mode, envelope: envelope)
    }

    /// Select builder by provider + model family, not just provider.
    /// Ollama running non-Gemma models gets OpenAI-style prose prompt.
    public static func builder(for provider: LLMProvider, modelID: String) -> any PromptBuilder {
        switch family(for: provider, modelID: modelID) {
        case .geminiPlain: return GeminiPromptBuilder()
        case .openAIProse: return OpenAIPromptBuilder()
        case .gemmaFewShot: return GemmaPromptBuilder()
        }
    }

    /// Map (provider, modelID) to a PromptFamily.
    public static func family(for provider: LLMProvider, modelID: String) -> PromptFamily {
        switch provider {
        case .gemini:
            return .geminiPlain
        case .openAI:
            return .openAIProse
        case .ollama:
            if modelID.lowercased().contains("gemma") {
                return .gemmaFewShot
            }
            return .openAIProse
        case .appleIntelligence, .none:
            // Should not reach planner. Fallback to openAI prose.
            return .openAIProse
        }
    }
}
