import Testing
@testable import EnviousWisprCore
@testable import EnviousWisprLLM

@Suite("GemmaPromptBuilder")
struct GemmaPromptBuilderTests {
    let builder = GemmaPromptBuilder()

    // MARK: - Helpers

    func makeInput(
        transcript: String = "hey um I was thinking we should ship this feature behind a flag",
        modelID: String = "gemma3:4b",
        language: String? = nil,
        customWords: [CustomWord] = [],
        customPromptMode: CustomPromptMode = .normal,
        customSystemPrompt: String? = nil
    ) -> PromptBuildInput {
        PromptBuildInput(
            transcript: transcript,
            provider: .ollama,
            modelID: modelID,
            stylePreset: .standard,
            customSystemPrompt: customSystemPrompt,
            customPromptMode: customPromptMode,
            appName: nil,  // Gemma: no appName (eval showed no quality difference)
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

    @Test("user message is plain transcript, no tags")
    func userMessagePlain() {
        let transcript = "test transcript"
        let envelope = builder.build(input: makeInput(transcript: transcript), mode: .message)
        #expect(envelope.messages[1].content == transcript)
    }

    // MARK: - Few-shot examples

    @Test("inline mode -> single prose example only")
    func inlineFewShot() {
        let envelope = builder.build(input: makeInput(), mode: .inline)
        let system = envelope.messages[0].content
        #expect(system.contains("Example:"))
        #expect(system.contains("running about ten minutes late"))
        #expect(!system.contains("Example 1:"))  // Not the multi-example format
    }

    @Test("message mode -> two examples (list + prose)")
    func messageFewShot() {
        let envelope = builder.build(input: makeInput(), mode: .message)
        let system = envelope.messages[0].content
        #expect(system.contains("Example 1:"))
        #expect(system.contains("Example 2:"))
        #expect(system.contains("- Call the dentist"))  // List formatting in example
        #expect(system.contains("running about ten minutes late"))  // Prose example
    }

    @Test("structured mode -> same examples as message")
    func structuredFewShot() {
        let envelope = builder.build(input: makeInput(), mode: .structured)
        let system = envelope.messages[0].content
        #expect(system.contains("Example 1:"))
        #expect(system.contains("Example 2:"))
    }

    // MARK: - No ASR clause (implicit via few-shot)

    @Test("no explicit ASR clause for Gemma")
    func noExplicitAsrClause() {
        let envelope = builder.build(input: makeInput(), mode: .message)
        let system = envelope.messages[0].content
        #expect(!system.contains("speech-to-text output"))
        #expect(!system.contains("phonetically similar"))
    }

    // MARK: - No context block

    @Test("no context block even with appName in input")
    func noContextBlock() {
        let input = PromptBuildInput(
            transcript: "test",
            provider: .ollama,
            modelID: "gemma3:4b",
            stylePreset: .standard,
            customSystemPrompt: nil,
            appName: "Slack",  // Intentionally passed
            language: nil,
            customWords: []
        )
        let envelope = builder.build(input: input, mode: .message)
        let system = envelope.messages[0].content
        // Gemma builder ignores appName (token budget too tight)
        #expect(!system.contains("Context"))
        #expect(!system.contains("App:"))
    }

    // MARK: - Custom vocabulary (simplified format)

    @Test("custom words use simplified comma format")
    func simplifiedVocab() {
        let words = [
            CustomWord(canonical: "EnviousWispr"),
            CustomWord(canonical: "Saurabh"),
        ]
        let envelope = builder.build(input: makeInput(customWords: words), mode: .message)
        let system = envelope.messages[0].content
        #expect(system.contains("Preferred spellings: EnviousWispr, Saurabh"))
        #expect(!system.contains("CUSTOM VOCABULARY"))  // Not the full header
    }

    // MARK: - Transcript prompt suffix

    @Test("system ends with 'Now clean up this text:'")
    func transcriptPromptSuffix() {
        let envelope = builder.build(input: makeInput(), mode: .message)
        let system = envelope.messages[0].content
        #expect(system.contains("Now clean up this text:"))
    }

    // MARK: - Weak model override

    @Test("weak model gets simplified prompt")
    func weakModel() {
        let envelope = builder.build(
            input: makeInput(modelID: "gemma2:2b"),
            mode: .structured
        )
        let system = envelope.messages[0].content
        #expect(system == "Fix grammar and punctuation. Return only the corrected text.")
        #expect(!system.contains("Example"))
    }

    // MARK: - Language

    @Test("non-English uses minimal language instruction")
    func nonEnglish() {
        let envelope = builder.build(input: makeInput(language: "es"), mode: .message)
        let system = envelope.messages[0].content
        #expect(system.contains("LANGUAGE: es. Keep the same language."))
    }

    // MARK: - Legacy template

    @Test("legacyTemplate wraps minimally")
    func legacyTemplate() {
        let envelope = builder.build(
            input: makeInput(
                customPromptMode: .legacyTemplate,
                customSystemPrompt: "Custom prompt text"
            ),
            mode: .message
        )
        let system = envelope.messages[0].content
        #expect(system.contains("Custom prompt text"))
        #expect(system.contains("Return only the final text."))
        #expect(!system.contains("Example"))
        #expect(envelope.messages[1].content.isEmpty)
    }

    // MARK: - No sandwich framing

    @Test("no <transcript> tags in Gemma prompt")
    func noSandwichFraming() {
        let envelope = builder.build(input: makeInput(), mode: .message)
        let user = envelope.messages[1].content
        #expect(!user.contains("<transcript>"))
    }
}
