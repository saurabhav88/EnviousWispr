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
    appName: String? = "Slack"
  ) -> PromptBuildInput {
    PromptBuildInput(
      transcript: transcript,
      provider: provider,
      modelID: modelID,
      appName: appName,
      language: nil,
      polishVocabulary: PolishVocabulary(terms: [], generation: 0)
    )
  }

  // MARK: - PromptFamily selection

  @Test("Gemini -> cloudFixed")
  func geminiFamily() {
    #expect(DefaultPromptPlanner.family(for: .gemini, modelID: "gemini-2.0-flash") == .cloudFixed)
    #expect(
      DefaultPromptPlanner.builder(for: .gemini, modelID: "gemini-2.0-flash")
        is CloudFixedPromptBuilder)
  }

  @Test("OpenAI -> cloudFixed")
  func openAIFamily() {
    #expect(DefaultPromptPlanner.family(for: .openAI, modelID: "gpt-4o-mini") == .cloudFixed)
    #expect(
      DefaultPromptPlanner.builder(for: .openAI, modelID: "gpt-4o-mini")
        is CloudFixedPromptBuilder)
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
    #expect(
      DefaultPromptPlanner.family(for: .appleIntelligence, modelID: "apple-intelligence")
        == .openAIProse)
  }

  // MARK: - Mode routing through planner

  // Mode routing through the planner is now meaningful ONLY for the mode-driven Ollama
  // path; the cloud providers are forced to `.message` (see cloudForcesMessageMode).

  @Test("short transcript -> inline mode in plan (Ollama)")
  func shortTranscriptMode() {
    let plan = planner.plan(
      input: makeInput(transcript: "hey call me back", provider: .ollama, modelID: "llama3.2"))
    #expect(plan.mode == .inline)
  }

  @Test("medium transcript -> message mode in plan (Ollama)")
  func mediumTranscriptMode() {
    let words = Array(repeating: "word", count: 50).joined(separator: " ")
    let plan = planner.plan(
      input: makeInput(transcript: words, provider: .ollama, modelID: "llama3.2"))
    #expect(plan.mode == .message)
  }

  @Test("long transcript -> structured mode in plan (Ollama)")
  func longTranscriptMode() {
    let words = Array(repeating: "word", count: 120).joined(separator: " ")
    let plan = planner.plan(
      input: makeInput(transcript: words, provider: .ollama, modelID: "llama3.2"))
    #expect(plan.mode == .structured)
  }

  @Test("cloud providers force .message mode regardless of length (#1255)")
  func cloudForcesMessageMode() {
    let short = planner.plan(
      input: makeInput(
        transcript: "hey call me back", provider: .gemini, modelID: "gemini-2.5-flash"))
    #expect(short.mode == .message)
    let longText = Array(repeating: "word", count: 120).joined(separator: " ")
    let longPlan = planner.plan(
      input: makeInput(transcript: longText, provider: .openAI, modelID: "gpt-4o"))
    #expect(longPlan.mode == .message)
  }

  // MARK: - Plan produces valid envelope

  @Test("plan always produces non-empty envelope")
  func planProducesEnvelope() {
    let plan = planner.plan(input: makeInput())
    #expect(!plan.envelope.messages.isEmpty)
    #expect(plan.envelope.messages[0].role == .system)
  }

  @Test("plan with empty transcript still produces valid output (Ollama analyzer -> inline)")
  func emptyTranscript() {
    let plan = planner.plan(
      input: makeInput(transcript: "", provider: .ollama, modelID: "llama3.2"))
    #expect(!plan.envelope.messages.isEmpty)
    #expect(plan.mode == .inline)
  }

  // MARK: - Builder selection produces correct prompt style

  @Test("Gemini plan uses the fixed v6 prompt with a plain user message")
  func geminiPlanStyle() {
    let plan = planner.plan(input: makeInput(provider: .gemini, modelID: "gemini-2.5-flash"))
    let system = plan.envelope.messages[0].content
    let user = plan.envelope.messages[1].content
    #expect(system.contains("You are the writing assistant inside a dictation app"))
    #expect(user.hasPrefix("Transcript to clean:"))
    #expect(!user.contains("<transcript>"))
  }

  @Test("OpenAI plan uses the fixed v6 prompt with a plain user message")
  func openAIPlanStyle() {
    let plan = planner.plan(input: makeInput(provider: .openAI, modelID: "gpt-4o-mini"))
    let system = plan.envelope.messages[0].content
    let user = plan.envelope.messages[1].content
    #expect(system.contains("You are the writing assistant inside a dictation app"))
    #expect(user.hasPrefix("Transcript to clean:"))
    #expect(!user.contains("<transcript>"))
  }

  @Test("Ollama Gemma plan uses few-shot prompt style")
  func ollamaGemmaPlanStyle() {
    let plan = planner.plan(input: makeInput(provider: .ollama, modelID: "gemma3:4b"))
    let system = plan.envelope.messages[0].content
    let user = plan.envelope.messages[1].content
    #expect(system.contains("Example"))
    #expect(system.contains("Now clean up this text:"))
    #expect(!user.contains("<transcript>"))
  }

  @Test("Ollama non-Gemma plan uses OpenAI prose prompt style")
  func ollamaNonGemmaPlanStyle() {
    let plan = planner.plan(input: makeInput(provider: .ollama, modelID: "llama3.2"))
    let system = plan.envelope.messages[0].content
    let user = plan.envelope.messages[1].content
    #expect(system.contains("Clean up this dictated transcript"))
    #expect(!system.contains("Now clean up this text:"))
    #expect(user.contains("<transcript>"))
  }
}
