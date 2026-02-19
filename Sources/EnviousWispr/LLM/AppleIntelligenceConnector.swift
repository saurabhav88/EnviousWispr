import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence connector using the on-device FoundationModels framework.
/// Requires macOS 26+ with Apple Intelligence support. No API key, no internet connection.
struct AppleIntelligenceConnector: TranscriptPolisher {

    /// Simplified default instructions for the on-device model.
    /// The full default prompt is too complex for Apple's small model.
    private static let onDeviceInstructions = """
        Clean this transcript:
        1. Fix spelling, capitalization, and punctuation errors
        2. Convert number words to digits (twenty-five → 25, ten percent → 10%)
        3. Replace spoken punctuation with symbols (period → ., comma → ,)
        4. Remove filler words (um, uh, like, you know)
        5. Keep the original language

        Preserve exact meaning and word order. Do not paraphrase or reorder.
        Return only the cleaned transcript.
        """

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

        // Use simplified instructions for Apple's on-device model when using
        // the default prompt. If the user set a custom prompt, respect it.
        let systemPrompt =
            instructions.systemPrompt == PolishInstructions.default.systemPrompt
            ? Self.onDeviceInstructions
            : instructions.systemPrompt

        let session = LanguageModelSession(
            model: model,
            instructions: systemPrompt
        )

        let response = try await session.respond(to: text)
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
