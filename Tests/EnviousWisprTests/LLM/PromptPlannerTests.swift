import Testing
@testable import EnviousWisprCore
@testable import EnviousWisprLLM

@Suite("DefaultPromptPlanner")
struct PromptPlannerTests {
    let planner = DefaultPromptPlanner()

    // MARK: - Helpers

    func makeInput(
        transcript: String = "hey um I was thinking we should ship this feature behind a flag",
        provider: LLMProvider = .gemini,
        modelID: String = "gemini-2.0-flash",
        appName: String? = "Slack",
        customPromptMode: CustomPromptMode = .normal,
        customSystemPrompt: String? = nil
    ) -> PromptBuildInput {
        PromptBuildInput(
            transcript: transcript,
            provider: provider,
            modelID: modelID,
            stylePreset: .standard,
            customSystemPrompt: customSystemPrompt,
            customPromptMode: customPromptMode,
            appName: appName,
            language: nil,
            customWords: []
        )
    }

    // MARK: - PromptFamily selection

    @Test("Gemini -> geminiPlain")
    func geminiFamily() {
        #expect(DefaultPromptPlanner.family(for: .gemini, modelID: "gemini-2.0-flash") == .geminiPlain)
    }

    @Test("OpenAI -> openAIProse")
    func openAIFamily() {
        #expect(DefaultPromptPlanner.family(for: .openAI, modelID: "gpt-4o-mini") == .openAIProse)
    }

    @Test("Ollama + gemma model -> gemmaFewShot")
    func ollamaGemmaFamily() {
        #expect(DefaultPromptPlanner.family(for: .ollama, modelID: "gemma3:4b") == .gemmaFewShot)
    }

    @Test("Ollama + Gemma uppercase -> gemmaFewShot")
    func ollamaGemmaUppercase() {
        #expect(DefaultPromptPlanner.family(for: .ollama, modelID: "Gemma-7B") == .gemmaFewShot)
    }

    @Test("Ollama + non-gemma model -> openAIProse")
    func ollamaNonGemmaFamily() {
        #expect(DefaultPromptPlanner.family(for: .ollama, modelID: "llama3.2") == .openAIProse)
    }

    @Test("Ollama + mistral -> openAIProse")
    func ollamaMistral() {
        #expect(DefaultPromptPlanner.family(for: .ollama, modelID: "mistral:7b") == .openAIProse)
    }

    @Test("appleIntelligence -> openAIProse (fallback, should not reach planner)")
    func appleIntelligenceFallback() {
        #expect(DefaultPromptPlanner.family(for: .appleIntelligence, modelID: "apple-intelligence") == .openAIProse)
    }

    // MARK: - Mode routing through planner

    @Test("short transcript -> inline mode in plan")
    func shortTranscriptMode() {
        let plan = planner.plan(input: makeInput(transcript: "hey call me back"))
        #expect(plan.mode == .inline)
    }

    @Test("medium transcript -> message mode in plan")
    func mediumTranscriptMode() {
        let words = Array(repeating: "word", count: 50).joined(separator: " ")
        let plan = planner.plan(input: makeInput(transcript: words))
        #expect(plan.mode == .message)
    }

    @Test("long transcript -> structured mode in plan")
    func longTranscriptMode() {
        let words = Array(repeating: "word", count: 120).joined(separator: " ")
        let plan = planner.plan(input: makeInput(transcript: words))
        #expect(plan.mode == .structured)
    }

    // MARK: - legacyTemplate mode routing

    @Test("legacyTemplate forces .message mode regardless of transcript length")
    func legacyTemplateForcesMessage() {
        let longText = Array(repeating: "word", count: 200).joined(separator: " ")
        let plan = planner.plan(
            input: makeInput(
                transcript: longText,
                customPromptMode: .legacyTemplate,
                customSystemPrompt: "Custom prompt with ${transcript}"
            )
        )
        #expect(plan.mode == .message)
    }

    @Test("legacyTemplate produces envelope with custom prompt, not builder default")
    func legacyTemplateContent() {
        let plan = planner.plan(
            input: makeInput(
                customPromptMode: .legacyTemplate,
                customSystemPrompt: "My custom instructions"
            )
        )
        let system = plan.envelope.messages[0].content
        #expect(system.contains("My custom instructions"))
    }

    // MARK: - Plan produces valid envelope

    @Test("plan always produces non-empty envelope")
    func planProducesEnvelope() {
        let plan = planner.plan(input: makeInput())
        #expect(!plan.envelope.messages.isEmpty)
        #expect(plan.envelope.messages[0].role == .system)
    }

    @Test("plan with empty transcript still produces valid output")
    func emptyTranscript() {
        let plan = planner.plan(input: makeInput(transcript: ""))
        #expect(!plan.envelope.messages.isEmpty)
        #expect(plan.mode == .inline)
    }

    // MARK: - Builder selection produces correct prompt style

    @Test("Gemini plan uses plain-label format, no XML")
    func geminiPlanStyle() {
        let plan = planner.plan(input: makeInput(provider: .gemini, modelID: "gemini-2.0-flash"))
        let system = plan.envelope.messages[0].content
        #expect(system.contains("rewrite dictated text"))
        #expect(!system.contains("<transcript>"))
    }

    @Test("OpenAI plan uses prose format with sandwich framing")
    func openAIPlanStyle() {
        let plan = planner.plan(input: makeInput(provider: .openAI, modelID: "gpt-4o-mini"))
        let user = plan.envelope.messages[1].content
        #expect(user.contains("<transcript>"))
    }

    @Test("Ollama Gemma plan uses few-shot examples")
    func ollamaGemmaPlanStyle() {
        let plan = planner.plan(input: makeInput(provider: .ollama, modelID: "gemma3:4b"))
        let system = plan.envelope.messages[0].content
        #expect(system.contains("Example"))
        #expect(system.contains("Now clean up this text:"))
    }

    @Test("Ollama non-Gemma plan uses OpenAI prose style")
    func ollamaNonGemmaPlanStyle() {
        let plan = planner.plan(input: makeInput(provider: .ollama, modelID: "llama3.2"))
        let system = plan.envelope.messages[0].content
        #expect(system.contains("Clean up this dictated transcript"))
    }
}
