import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence connector using the on-device FoundationModels framework.
/// Requires macOS 26+ with Apple Intelligence support. No API key, no internet connection.
struct AppleIntelligenceConnector: TranscriptPolisher {

    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig
    ) async throws -> LLMResult {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw LLMError.frameworkUnavailable
        }
        return try await polishWithFoundationModels(text: text, instructions: instructions)
#else
        throw LLMError.frameworkUnavailable
#endif
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func polishWithFoundationModels(
        text: String,
        instructions: PolishInstructions
    ) async throws -> LLMResult {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw LLMError.frameworkUnavailable
        }

        let session = LanguageModelSession(model: model)
        let fullPrompt = """
            \(instructions.systemPrompt)

            ---

            \(text)
            """

        let response = try await session.respond(to: Prompt(fullPrompt))
        let content = response.content

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyResponse
        }

        return LLMResult(
            polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: .appleIntelligence,
            model: "apple-intelligence"
        )
    }
#endif
}
