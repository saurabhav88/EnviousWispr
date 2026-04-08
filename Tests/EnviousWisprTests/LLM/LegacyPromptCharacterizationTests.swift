import Foundation
import Testing
@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// Characterization tests that freeze the current enrichedInstructions() behavior.
/// These must pass before AND after PR 2 replaces the old prompt path.
/// Fixture values from plan Appendix F5.
@Suite("Legacy Prompt Characterization")
struct LegacyPromptCharacterizationTests {

    // MARK: - Shared fixtures

    static let standardPrompt = PolishInstructions.default.systemPrompt
    static let formalPrompt = PromptPreset.formal.systemPrompt
    static let casualPrompt = PromptPreset.casual.systemPrompt

    static let sampleTranscript50w = """
        so I was thinking about the project and um we really need to get the \
        API documentation done before the end of the week because the client \
        is going to start integration testing on Monday and they need the \
        endpoints documented so they know what to call and what parameters \
        to send in the request body
        """

    static let sampleTranscript7w = "hey can you call me back"

    static let sampleCustomWords: [CustomWord] = [
        CustomWord(canonical: "EnviousWispr", aliases: ["envious whisper", "envious wisper"]),
        CustomWord(canonical: "Saurabh", aliases: ["sorab", "surav"]),
    ]

    // MARK: - Standard preset, baseline

    @Test("standard preset with appName produces ASR clause and app context")
    func standardWithApp() {
        let result = LegacyPromptEnricher.enrich(
            baseSystemPrompt: Self.standardPrompt,
            language: nil,
            transcript: Self.sampleTranscript50w,
            targetAppName: "Slack",
            customWords: []
        )

        // Must start with the standard prompt (no language prepend)
        #expect(result.hasPrefix("Clean up this speech-to-text transcript."))
        // Must contain ASR-awareness clause
        #expect(result.contains("phonetically similar but contextually incorrect words"))
        // Must contain app context
        #expect(result.contains("The user is dictating in Slack."))
        // Must NOT contain short-text guard (50 words > 10)
        #expect(!result.contains("IMPORTANT: If the transcript is very short"))
        // Must NOT contain custom vocabulary
        #expect(!result.contains("CUSTOM VOCABULARY"))
    }

    // MARK: - No app context path

    @Test("standard preset without appName omits app context line")
    func standardNoApp() {
        let result = LegacyPromptEnricher.enrich(
            baseSystemPrompt: Self.standardPrompt,
            language: nil,
            transcript: Self.sampleTranscript50w,
            targetAppName: nil,
            customWords: []
        )

        #expect(result.contains("phonetically similar but contextually incorrect words"))
        #expect(!result.contains("The user is dictating in"))
    }

    // MARK: - Non-English language path

    @Test("non-English language prepends LANGUAGE block")
    func nonEnglishLanguage() {
        let result = LegacyPromptEnricher.enrich(
            baseSystemPrompt: Self.standardPrompt,
            language: "es",
            transcript: Self.sampleTranscript50w,
            targetAppName: nil,
            customWords: []
        )

        // Must start with LANGUAGE block
        #expect(result.hasPrefix("LANGUAGE: This transcript is in"))
        // Must contain language code
        #expect(result.contains("(es)"))
        // Must contain "do NOT translate to English"
        #expect(result.contains("do NOT translate to English"))
        // The standard prompt must follow after the language block
        #expect(result.contains("Clean up this speech-to-text transcript."))
    }

    @Test("English language code does NOT trigger language block")
    func englishLanguageSkipped() {
        let result = LegacyPromptEnricher.enrich(
            baseSystemPrompt: Self.standardPrompt,
            language: "en",
            transcript: Self.sampleTranscript50w,
            targetAppName: nil,
            customWords: []
        )

        #expect(!result.contains("LANGUAGE:"))
        #expect(result.hasPrefix("Clean up this speech-to-text transcript."))
    }

    // MARK: - Custom vocabulary injection

    @Test("custom words appended with correct format")
    func customVocabulary() {
        let result = LegacyPromptEnricher.enrich(
            baseSystemPrompt: Self.standardPrompt,
            language: nil,
            transcript: Self.sampleTranscript50w,
            targetAppName: "Slack",
            customWords: Self.sampleCustomWords
        )

        #expect(result.contains("CUSTOM VOCABULARY: The following are the user's preferred spellings"))
        #expect(result.contains("- EnviousWispr (may be misheard as: envious whisper, envious wisper)"))
        #expect(result.contains("- Saurabh (may be misheard as: sorab, surav)"))
    }

    // MARK: - Short-text guard

    @Test("short transcript (<=10 words) triggers short-text guard")
    func shortTextGuard() {
        let result = LegacyPromptEnricher.enrich(
            baseSystemPrompt: Self.standardPrompt,
            language: nil,
            transcript: Self.sampleTranscript7w,
            targetAppName: nil,
            customWords: []
        )

        #expect(result.contains("IMPORTANT: If the transcript is very short"))
        #expect(result.contains("Do NOT expand, elaborate, or generate new content"))
    }

    @Test("transcript above 10 words does NOT trigger short-text guard")
    func noShortTextGuard() {
        let result = LegacyPromptEnricher.enrich(
            baseSystemPrompt: Self.standardPrompt,
            language: nil,
            transcript: Self.sampleTranscript50w,
            targetAppName: nil,
            customWords: []
        )

        #expect(!result.contains("IMPORTANT: If the transcript is very short"))
    }

    // MARK: - Formal preset

    @Test("formal preset uses formal base prompt")
    func formalPreset() {
        let result = LegacyPromptEnricher.enrich(
            baseSystemPrompt: Self.formalPrompt,
            language: nil,
            transcript: Self.sampleTranscript50w,
            targetAppName: "Slack",
            customWords: []
        )

        #expect(result.hasPrefix("You are a professional editor."))
        #expect(result.contains("phonetically similar but contextually incorrect words"))
        #expect(result.contains("The user is dictating in Slack."))
    }

    // MARK: - Casual preset

    @Test("casual preset uses casual base prompt")
    func casualPreset() {
        let result = LegacyPromptEnricher.enrich(
            baseSystemPrompt: Self.casualPrompt,
            language: nil,
            transcript: Self.sampleTranscript50w,
            targetAppName: "Slack",
            customWords: []
        )

        #expect(result.hasPrefix("You are a friendly editor."))
        #expect(result.contains("phonetically similar but contextually incorrect words"))
    }

    // MARK: - Combined: all enrichments active

    @Test("all enrichments active: language + ASR + app + short-text + vocab")
    func allEnrichmentsActive() {
        let result = LegacyPromptEnricher.enrich(
            baseSystemPrompt: Self.standardPrompt,
            language: "fr",
            transcript: Self.sampleTranscript7w,
            targetAppName: "Messages",
            customWords: Self.sampleCustomWords
        )

        // Language block first
        #expect(result.hasPrefix("LANGUAGE:"))
        // Standard prompt embedded
        #expect(result.contains("Clean up this speech-to-text transcript."))
        // ASR clause
        #expect(result.contains("phonetically similar but contextually incorrect words"))
        // App context
        #expect(result.contains("The user is dictating in Messages."))
        // Short-text guard
        #expect(result.contains("IMPORTANT: If the transcript is very short"))
        // Custom vocab
        #expect(result.contains("CUSTOM VOCABULARY"))
        #expect(result.contains("EnviousWispr"))
    }
}
