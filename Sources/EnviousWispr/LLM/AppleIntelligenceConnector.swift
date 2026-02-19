import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence connector using the on-device FoundationModels framework.
/// Requires macOS 26+ with Apple Intelligence support. No API key, no internet connection.
struct AppleIntelligenceConnector: TranscriptPolisher {

    /// Simplified default instructions for the on-device model.
    /// The full default prompt is too complex for Apple's small ~3B model.
    private static let onDeviceInstructions = """
        Proofread this speech transcript. Fix ONLY:
        - Punctuation and capitalization
        - Obvious misheard words from context
        - Remove filler words (um, uh, like, you know)

        Do NOT rephrase, add, or remove any other words.
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

    // MARK: - Guided generation with @Generable (preferred path)
    // Uses structured output to prevent the model from adding preamble text.
    // Requires the FoundationModelsMacros plugin (ships with full Xcode toolchain).

#if canImport(FoundationModels) && hasAttribute(Generable)
    @Generable
    @available(macOS 26.0, *)
    struct CleanedTranscript {
        @Guide(description: "The cleaned transcript text only, with no preamble or commentary")
        var text: String
    }

    @available(macOS 26.0, *)
    private func polishWithFoundationModels(
        text: String,
        instructions: PolishInstructions
    ) async throws -> LLMResult {
        let session = try makeSession(instructions: instructions)

        let response = try await session.respond(to: text, generating: CleanedTranscript.self)
        let content = response.text

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyResponse
        }

        return LLMResult(
            polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines)
                .strippingLLMPreamble(),
            provider: .appleIntelligence,
            model: "apple-intelligence"
        )
    }

    // MARK: - Plain text fallback (CLT-only builds without macro plugin)

#elseif canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func polishWithFoundationModels(
        text: String,
        instructions: PolishInstructions
    ) async throws -> LLMResult {
        let session = try makeSession(instructions: instructions)

        let response = try await session.respond(to: text)
        let content = response.content

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyResponse
        }

        return LLMResult(
            polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines)
                .strippingLLMPreamble(),
            provider: .appleIntelligence,
            model: "apple-intelligence"
        )
    }
#endif

    // MARK: - Shared session setup

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func makeSession(instructions: PolishInstructions) throws -> LanguageModelSession {
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

        return LanguageModelSession(
            model: model,
            instructions: systemPrompt
        )
    }
#endif
}
