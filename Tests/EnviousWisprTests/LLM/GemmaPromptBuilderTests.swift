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
    customWords: [CustomWord] = []
  ) -> PromptBuildInput {
    PromptBuildInput(
      transcript: transcript,
      provider: .ollama,
      modelID: modelID,
      appName: nil,  // Gemma: no appName (eval showed no quality difference)
      language: language,
      polishVocabulary: PolishVocabulary(terms: customWords, generation: 0)
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
  // MARK: - No ASR clause (implicit via few-shot)
  // MARK: - No context block
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

  // MARK: - No sandwich framing

  @Test("no <transcript> tags in Gemma prompt")
  func noSandwichFraming() {
    let envelope = builder.build(input: makeInput(), mode: .message)
    let user = envelope.messages[1].content
    #expect(!user.contains("<transcript>"))
  }
}
