import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

@Suite("CloudFixedPromptBuilder")
struct CloudFixedPromptBuilderTests {
  let builder = CloudFixedPromptBuilder()

  // v6 signature line — a stable substring of the fixed prompt.
  let v6Signature = "You are the writing assistant inside a dictation app"

  func makeInput(
    transcript: String = "hey um I was thinking we should ship this feature behind a flag today",
    appName: String? = nil,
    language: String? = nil,
    vocab: [CustomWord] = []
  ) -> PromptBuildInput {
    PromptBuildInput(
      transcript: transcript,
      provider: .openAI,
      modelID: "gpt-4o",
      appName: appName,
      language: language,
      polishVocabulary: PolishVocabulary(terms: vocab, generation: 0)
    )
  }

  func system(_ input: PromptBuildInput, _ mode: PolishMode = .message) -> String {
    builder.build(input: input, mode: mode).messages[0].content
  }

  func user(_ input: PromptBuildInput, _ mode: PolishMode = .message) -> String {
    builder.build(input: input, mode: mode).messages[1].content
  }

  // MARK: - Fixed prompt + plain user message

  @Test("system carries the fixed v6 prompt; user is a plain 'Transcript to clean' message")
  func fixedPromptAndPlainUser() {
    let input = makeInput()
    #expect(system(input).contains(v6Signature))
    #expect(user(input) == "Transcript to clean:\n\n\(input.transcript)")
    #expect(!user(input).contains("<transcript>"))
    #expect(!system(input).contains("<transcript>"))
  }

  // MARK: - Mode invariance (the whole premise: no per-transcript segregation)

  @Test("mode is ignored — inline and structured produce identical envelopes")
  func modeInvariance() {
    let input = makeInput()
    let inline = builder.build(input: input, mode: .inline)
    let structured = builder.build(input: input, mode: .structured)
    #expect(inline.messages[0].content == structured.messages[0].content)
    #expect(inline.messages[1].content == structured.messages[1].content)
    // And .edit / .message match too.
    #expect(system(input, .edit) == system(input, .message))
  }

  // MARK: - Enrichments present when set, absent when not

  @Test("non-English language prefix present when set, absent when nil")
  func languagePrefix() {
    #expect(system(makeInput(language: "Spanish")).contains("This transcript is in Spanish"))
    #expect(!system(makeInput(language: nil)).contains("LANGUAGE:"))
    #expect(!system(makeInput(language: "")).contains("LANGUAGE:"))
  }

  // #1255 Codex r4 regression: the retired Gemini base carried an UNCONDITIONAL
  // "never translate" rule. `input.language` is set only in locked mode, so the
  // no-translate guarantee must NOT depend on it — an auto-detected non-English
  // transcript (language == nil here) must still get it.
  @Test("unconditional no-translate rule is present regardless of language mode")
  func unconditionalLanguagePreservation() {
    for lang in [nil, "", "Spanish"] as [String?] {
      let s = system(makeInput(language: lang))
      #expect(s.contains("Never translate it"))
      #expect(s.contains("same language(s) and script(s)"))
    }
  }

  @Test("app-name context line present when set, absent when nil")
  func appNameContext() {
    #expect(system(makeInput(appName: "Slack")).contains("dictating in Slack"))
    #expect(!system(makeInput(appName: nil)).contains("The user is dictating in"))
  }

  @Test("short-input safety hint fires for <=10 words, not for longer input")
  func shortInputGuard() {
    #expect(system(makeInput(transcript: "call me back later please")).contains("Very short input"))
    let long = Array(repeating: "word", count: 20).joined(separator: " ")
    #expect(!system(makeInput(transcript: long)).contains("Very short input"))
  }

  @Test("custom vocabulary is framed as an explicit exception, absent when empty")
  func vocabFraming() {
    let withVocab = makeInput(vocab: [CustomWord(canonical: "EnviousWispr")])
    let s = system(withVocab)
    #expect(s.contains("preferred spellings"))
    #expect(s.contains("one exception to leaving the wording unchanged"))
    #expect(s.contains("EnviousWispr"))
    #expect(!system(makeInput(vocab: [])).contains("preferred spellings"))
  }

  // MARK: - Enrichment-ON combinations (Codex C3)

  @Test("non-English + custom vocab both present coherently")
  func languagePlusVocab() {
    let s = system(makeInput(language: "French", vocab: [CustomWord(canonical: "EnviousWispr")]))
    #expect(s.contains("This transcript is in French"))
    #expect(s.contains("EnviousWispr"))
    #expect(s.contains(v6Signature))
  }

  @Test("very short + app hint both present")
  func shortPlusAppName() {
    let s = system(makeInput(transcript: "ship it now", appName: "Notes"))
    #expect(s.contains("Very short input"))
    #expect(s.contains("dictating in Notes"))
    #expect(s.contains(v6Signature))
  }

  @Test("list-shaped input + custom spelling — vocab and fixed prompt coexist")
  func listPlusVocab() {
    let s = system(
      makeInput(
        transcript: "grab milk bread eggs and coffee on the way home from EnviousWispr",
        vocab: [CustomWord(canonical: "EnviousWispr")]))
    #expect(s.contains(v6Signature))
    #expect(s.contains("preferred spellings"))
  }
}
