import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence connector using the on-device FoundationModels framework.
/// Requires macOS 26+ with Apple Intelligence support. No API key, no internet connection.
struct AppleIntelligenceConnector: TranscriptPolisher {

    /// Simplified default instructions for the on-device model.
    /// Mirrors Handy's numbered-list format which works well with Apple's small model.
    /// The "Transcript:" label at the end primes the model to expect transcript input.
    private static let onDeviceInstructions = """
        Clean this transcript:
        1. Fix spelling, capitalization, and punctuation errors
        2. Remove filler words (um, uh, like, you know)
        3. Correct misheard words from context

        Preserve exact meaning and word order. DO NOT paraphrase or reorder content.
        DO NOT respond conversationally. DO NOT add commentary or greetings.
        Return ONLY the cleaned transcript.

        Transcript:
        """

    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig,
        onToken: (@Sendable (String) -> Void)?
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

        let wrappedText = text
        let response = try await session.respond(to: wrappedText, generating: CleanedTranscript.self)
        let content = response.text

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyResponse
        }

        return LLMResult(
            polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines)
                .strippingLLMPreamble()
        )
    }

    // MARK: - Dynamic schema fallback (CLT-only builds without macro plugin)
    // Uses DynamicGenerationSchema for constrained decoding — forces the model
    // to populate a schema field instead of responding conversationally.

#elseif canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func polishWithFoundationModels(
        text: String,
        instructions: PolishInstructions
    ) async throws -> LLMResult {
        let session = try makeSession(instructions: instructions)

        // Build a single-property schema that constrains the model to produce
        // structured output with a "text" field, preventing conversational replies.
        let dynamicSchema = DynamicGenerationSchema(
            name: "TranscriptResult",
            properties: [
                DynamicGenerationSchema.Property(
                    name: "text",
                    schema: DynamicGenerationSchema(type: String.self)
                )
            ]
        )
        let schema = try GenerationSchema(root: dynamicSchema, dependencies: [])

        let response = try await session.respond(
            to: "Proofread this transcript:\n\(text)",
            schema: schema
        )
        let content = try response.content.value(String.self, forProperty: "text")

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyResponse
        }

        return LLMResult(
            polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines)
                .strippingLLMPreamble()
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
