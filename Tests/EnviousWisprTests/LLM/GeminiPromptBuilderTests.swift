import Testing
@testable import EnviousWisprCore
@testable import EnviousWisprLLM

@Suite("GeminiPromptBuilder")
struct GeminiPromptBuilderTests {
    let builder = GeminiPromptBuilder()

    // MARK: - Helpers

    func makeInput(
        transcript: String = "hey um I was thinking we should ship this feature behind a flag",
        appName: String? = "Slack",
        language: String? = nil,
        customWords: [CustomWord] = [],
        customPromptMode: CustomPromptMode = .normal,
        customSystemPrompt: String? = nil
    ) -> PromptBuildInput {
        PromptBuildInput(
            transcript: transcript,
            provider: .gemini,
            modelID: "gemini-2.0-flash",
            stylePreset: .standard,
            customSystemPrompt: customSystemPrompt,
            customPromptMode: customPromptMode,
            appName: appName,
            language: language,
            customWords: customWords
        )
    }

    // MARK: - Basic structure

    @Test("produces system + user messages")
    func basicStructure() {
        let envelope = builder.build(input: makeInput(), mode: .message)
        #expect(envelope.messages.count == 2)
        #expect(envelope.messages[0].role == .system)
        #expect(envelope.messages[1].role == .user)
    }

    @Test("asSingleTurn succeeds for standard envelope")
    func singleTurnExtraction() {
        let envelope = builder.build(input: makeInput(), mode: .message)
        let pair = envelope.asSingleTurn()
        #expect(pair != nil)
        #expect(pair?.system != nil)
    }

    @Test("user message is plain transcript, no tags")
    func userMessagePlain() {
        let transcript = "test transcript here"
        let envelope = builder.build(input: makeInput(transcript: transcript), mode: .message)
        #expect(envelope.messages[1].content == transcript)
    }

    // MARK: - Base instruction

    @Test("base instruction uses 'rewrite' not 'polish'")
    func noPolishVerb() {
        let envelope = builder.build(input: makeInput(), mode: .message)
        let system = envelope.messages[0].content
        #expect(system.contains("rewrite dictated text"))
        #expect(!system.contains("Polish"))
        #expect(!system.contains("polish"))
    }

    // MARK: - ASR clause

    @Test("ASR-awareness clause always present")
    func asrClause() {
        let envelope = builder.build(input: makeInput(), mode: .inline)
        let system = envelope.messages[0].content
        #expect(system.contains("speech-to-text output"))
        #expect(system.contains("phonetically similar"))
    }

    // MARK: - Context block

    @Test("appName present -> context block included")
    func contextWithApp() {
        let envelope = builder.build(input: makeInput(appName: "Slack"), mode: .message)
        let system = envelope.messages[0].content
        #expect(system.contains("# Context\nApp: Slack"))
    }

    @Test("appName nil -> no context block")
    func contextWithoutApp() {
        let envelope = builder.build(input: makeInput(appName: nil), mode: .message)
        let system = envelope.messages[0].content
        #expect(!system.contains("# Context"))
    }

    // MARK: - Mode-specific formatting

    @Test("inline mode -> no bullets, no headers")
    func inlineFormatting() {
        let envelope = builder.build(input: makeInput(), mode: .inline)
        let system = envelope.messages[0].content
        #expect(system.contains("output one paragraph only"))
        #expect(system.contains("No bullets, headers, or line breaks"))
    }

    @Test("message mode -> TASK block with paragraphs and bullets rules")
    func messageFormatting() {
        let envelope = builder.build(input: makeInput(appName: "Slack"), mode: .message)
        let system = envelope.messages[0].content
        #expect(system.contains("mode: message"))
        #expect(system.contains("paragraphs: only at topic shifts"))
        #expect(system.contains("headers: no"))
    }

    @Test("structured mode -> TASK block with full formatting")
    func structuredFormatting() {
        let envelope = builder.build(input: makeInput(appName: "Slack"), mode: .structured)
        let system = envelope.messages[0].content
        #expect(system.contains("mode: structured"))
        #expect(system.contains("bullets: only if listing items"))
        #expect(system.contains("headers: only if clearly needed"))
    }

    // MARK: - Short-text guard

    @Test("short transcript triggers guard")
    func shortTextGuard() {
        let envelope = builder.build(input: makeInput(transcript: "call me back"), mode: .inline)
        let system = envelope.messages[0].content
        #expect(system.contains("IMPORTANT: Very short input"))
    }

    @Test("long transcript does not trigger guard")
    func noShortTextGuard() {
        let envelope = builder.build(input: makeInput(), mode: .message)
        let system = envelope.messages[0].content
        #expect(!system.contains("IMPORTANT: Very short input"))
    }

    // MARK: - Custom vocabulary

    @Test("custom words appended with full format")
    func customVocab() {
        let words = [CustomWord(canonical: "EnviousWispr", aliases: ["envious whisper"])]
        let envelope = builder.build(input: makeInput(customWords: words), mode: .message)
        let system = envelope.messages[0].content
        #expect(system.contains("CUSTOM VOCABULARY"))
        #expect(system.contains("EnviousWispr"))
    }

    @Test("empty custom words -> no vocab block")
    func emptyVocab() {
        let envelope = builder.build(input: makeInput(customWords: []), mode: .message)
        let system = envelope.messages[0].content
        #expect(!system.contains("CUSTOM VOCABULARY"))
    }

    // MARK: - Language

    @Test("non-English language prepends LANGUAGE block with 'Rewrite'")
    func nonEnglish() {
        let envelope = builder.build(input: makeInput(language: "es"), mode: .message)
        let system = envelope.messages[0].content
        #expect(system.hasPrefix("LANGUAGE: This transcript is in es."))
        #expect(system.contains("Rewrite it in es."))
    }

    @Test("nil language -> no LANGUAGE block")
    func nilLanguage() {
        let envelope = builder.build(input: makeInput(language: nil), mode: .message)
        let system = envelope.messages[0].content
        #expect(!system.contains("LANGUAGE:"))
    }

    // MARK: - Legacy template

    @Test("legacyTemplate wraps custom prompt minimally")
    func legacyTemplate() {
        let customPrompt = "Rewrite this in pirate speak: ${transcript}"
        let envelope = builder.build(
            input: makeInput(
                customPromptMode: .legacyTemplate,
                customSystemPrompt: customPrompt
            ),
            mode: .message
        )
        let system = envelope.messages[0].content
        // Must contain the custom prompt
        #expect(system.contains("Rewrite this in pirate speak"))
        // Must have safety net
        #expect(system.contains("Return only the final text."))
        // Must NOT contain builder's own base instruction
        #expect(!system.contains("rewrite dictated text for direct paste"))
        // Must NOT contain ASR clause
        #expect(!system.contains("speech-to-text output"))
        // User message must be empty
        #expect(envelope.messages[1].content.isEmpty)
    }

    @Test("legacyTemplate with non-English prepends language")
    func legacyTemplateWithLanguage() {
        let envelope = builder.build(
            input: makeInput(
                language: "fr",
                customPromptMode: .legacyTemplate,
                customSystemPrompt: "Custom prompt"
            ),
            mode: .message
        )
        let system = envelope.messages[0].content
        #expect(system.hasPrefix("LANGUAGE:"))
        #expect(system.contains("Custom prompt"))
    }

    // MARK: - No XML tags

    @Test("no angle brackets in Gemini prompt")
    func noXmlTags() {
        let envelope = builder.build(input: makeInput(), mode: .structured)
        let system = envelope.messages[0].content
        let user = envelope.messages[1].content
        #expect(!system.contains("<transcript>"))
        #expect(!system.contains("<task>"))
        #expect(!system.contains("<context>"))
        #expect(!user.contains("<transcript>"))
    }
}
