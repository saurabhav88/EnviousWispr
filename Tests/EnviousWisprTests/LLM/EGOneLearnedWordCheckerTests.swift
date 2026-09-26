import EnviousWisprCore
import Foundation
import os
import Testing

@testable import EnviousWisprLLM

@Suite("EG-1 learned-word adapter wire contract (#3105)", .tags(.driftGuard))
struct EGOneLearnedWordCheckerTests {
  private static func question() -> LearnedWordCheckQuestion {
    let sentence = "I said toast"
    return LearnedWordCheckQuestion(
      id: 7, sentence: sentence, range: sentence.range(of: "toast")!,
      contextRange: sentence.startIndex..<sentence.endIndex, word: "Tuist")
  }

  @Test func trainedChatMLPromptIsPinned() {
    let expected =
      "<|im_start|>system\n[Task: check] A word from the user's dictionary may have been misheard in a dictated sentence. A is the sentence as transcribed. B writes the dictionary word at one spot. Answer B only if the speaker meant the dictionary word there; otherwise answer A. Answer with one letter.<|im_end|>\n<|im_start|>user\nDictionary word: Tuist\nA: I said toast\nB: I said Tuist<|im_end|>\n<|im_start|>assistant\n"
    #expect(EGOneLearnedWordChecker.prompt(for: Self.question()) == expected)
  }

  /// Pinned to the text D5 was trained and graded with (hint-validation
  /// train_checker_distill.py through the HF chat template, enable_thinking=False;
  /// judge2-exam-v2/s1_mac_score.py): the same system text, the named-language line
  /// for the exam's eight languages, and the empty think block.
  @Test("S1-mini asks D5's trained question: think block, and the language line outside English")
  func s1MiniPromptIsPinned() {
    let q = Self.question()
    let english = EGOneLearnedWordChecker.prompt(for: q, style: .s1Mini(language: "en"))
    #expect(
      english == "<|im_start|>system\n\(EGOneLearnedWordChecker.systemPrompt)<|im_end|>\n"
        + "<|im_start|>user\nDictionary word: Tuist\nA: I said toast\nB: I said Tuist<|im_end|>\n"
        + "<|im_start|>assistant\n<think>\n\n</think>\n\n")
    let german = EGOneLearnedWordChecker.prompt(for: q, style: .s1Mini(language: "de"))
    #expect(german.contains("Answer with one letter. The sentence is in German.<|im_end|>"))
    // A regional code names its base language (Codex whole-diff review of #3105 PR 1).
    for regional in ["de-DE", "DE_at", " de-CH "] {
      #expect(EGOneLearnedWordChecker.prompt(for: q, style: .s1Mini(language: regional)) == german)
    }
    #expect(
      EGOneLearnedWordChecker.prompt(for: q, style: .s1Mini(language: "pt-BR"))
        .contains("The sentence is in Portuguese.<|im_end|>"))
    let unnamed = EGOneLearnedWordChecker.prompt(for: q, style: .s1Mini(language: "ja"))
    #expect(unnamed == english)
    #expect(EGOneLearnedWordChecker.prompt(for: q, style: .s1Mini(language: nil)) == english)
    #expect(EGOneLearnedWordChecker.prompt(for: q).hasSuffix("<|im_start|>assistant\n"))
    let checker = EGOneLearnedWordChecker(threshold: 0.5, style: .s1Mini(language: "fr")) {
      nil as EGOneCheckerHold?
    }
    #expect(checker.armName == "s1_lora")
    let body = EGOneLearnedWordChecker.makeRequestBody(q, index: 0, style: .s1Mini(language: "fr"))
    #expect((body["prompt"] as? String)?.contains("The sentence is in French.") == true)
  }

  @Test func multiSentencePromptShowsOnlyTheSpotSentence() {
    let text = "We use cotton daily. The plot twist surprised me."
    let question = LearnedWordCheckQuestion(
      id: 0, sentence: text, range: text.range(of: "twist")!,
      contextRange: text.range(of: "The plot twist surprised me.")!, word: "Tuist")
    let prompt = EGOneLearnedWordChecker.prompt(for: question)
    #expect(prompt.contains("A: The plot twist surprised me.\n"))
    #expect(prompt.contains("B: The plot Tuist surprised me.<|im_end|>"))
    #expect(prompt.contains("We use cotton daily.") == false)
  }

  @Test func eachRequestCarriesOnePromptAndItsCheckerSlot() {
    let checker = EGOneLearnedWordChecker(threshold: 0.5) { nil as EGOneCheckerHold? }
    #expect(checker.armName == "eg1_lora")
    #expect(checker.scoresAreComparable)
    let body = EGOneLearnedWordChecker.makeRequestBody(Self.question(), index: 0)
    #expect(body["prompt"] as? String == EGOneLearnedWordChecker.prompt(for: Self.question()))
    #expect(body["id_slot"] as? Int == 1)
    let sentence = "We said coffee"
    let second = LearnedWordCheckQuestion(
      id: 8, sentence: sentence, range: sentence.range(of: "coffee")!,
      contextRange: sentence.startIndex..<sentence.endIndex, word: "Kaggle")
    let secondBody = EGOneLearnedWordChecker.makeRequestBody(second, index: 1)
    #expect(secondBody["prompt"] as? String == EGOneLearnedWordChecker.prompt(for: second))
    #expect(secondBody["id_slot"] as? Int == 2)
    let secondLoRA = secondBody["lora"] as? [[String: Any]]
    #expect(secondLoRA?.first?["id"] as? Int == 0)
    #expect(secondLoRA?.first?["scale"] as? Double == 1.0)
    #expect(body["n_predict"] as? Int == 1)
    #expect(body["n_probs"] as? Int == 20)
    #expect(body["temperature"] as? Int == 0)
    #expect(body["cache_prompt"] as? Bool == true)
    let lora = body["lora"] as? [[String: Any]]
    #expect(lora?.count == 1)
    #expect(lora?.first?["id"] as? Int == 0)
    #expect(lora?.first?["scale"] as? Double == 1.0)
  }

  @Test("a check that fails still releases its server hold; no hold, no check")
  func failedCheckReleasesHold() async {
    let released = OSAllocatedUnfairLock<Int>(initialState: 0)
    let bare = EGOneEndpoint(port: 1, authToken: "t", contextTokens: 4096)
    let checker = EGOneLearnedWordChecker(threshold: 0.5) {
      EGOneCheckerHold(endpoint: bare) { released.withLock { $0 += 1 } }
    }
    await #expect(throws: EGOneLearnedWordChecker.CheckerError.self) {
      try await checker.decide([Self.question()])
    }
    #expect(released.withLock { $0 } == 1)
    let refused = EGOneLearnedWordChecker(threshold: 0.5) { nil as EGOneCheckerHold? }
    await #expect(throws: EGOneLearnedWordChecker.CheckerError.self) {
      try await refused.decide([Self.question()])
    }
  }

  @Test func checkerSlotsWrapAfterEightQuestions() {
    let slots = (0..<16).map {
      EGOneLearnedWordChecker.makeRequestBody(Self.question(), index: $0)["id_slot"] as? Int
    }
    #expect(slots == [1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8])
  }

  @Test("the adapter loads at scale 0 on a configured EG-1 or S1-mini launch, never on a bare one")
  func adapterFlagsAreOnlyOnConfiguredLaunch() {
    let path = URL(fileURLWithPath: "/tmp/check.gguf")
    let baseline = ["-fa", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0"]
    #expect(EGOneRuntime.launchArguments(for: .egOne, learnedWordAdapterURL: nil) == baseline)
    #expect(
      EGOneRuntime.launchArguments(for: .egOne, learnedWordAdapterURL: path)
        == baseline + [
          "--lora-scaled", "\(path.path):0",
          "-np", "9", "--kv-unified", "--no-cache-idle-slots",
        ])
    #expect(
      EGOneRuntime.launchArguments(for: .s1Mini, learnedWordAdapterURL: path)
        == baseline + ["--jinja", "--chat-template-kwargs", #"{"enable_thinking":false}"#]
        + [
          "--lora-scaled", "\(path.path):0",
          "-np", "9", "--kv-unified", "--no-cache-idle-slots",
        ])
    #expect(
      EGOneRuntime.launchArguments(for: .s1Mini, learnedWordAdapterURL: nil)
        == baseline + ["--jinja", "--chat-template-kwargs", #"{"enable_thinking":false}"#])
    // The server splits `--lora-scaled` on "," and ":": such a path boots without the adapter.
    for odd in ["/tmp/a,b/check.gguf", "/tmp/a:b/check.gguf"] {
      #expect(
        EGOneRuntime.launchArguments(for: .egOne, learnedWordAdapterURL: URL(fileURLWithPath: odd))
          == baseline)
    }
  }

  /// A real one-question reply from the same engine and adapter: a one-prompt array comes
  /// back as a bare object, not a one-element array (bench run 2026-09-23 logged
  /// `reason=checker_error` for every take with a single flagged spot before this).
  private static let realSingleReply = #"{"index":0,"completion_probabilities":[{"top_logprobs":[{"token":"A","logprob":-1.1920935776288388e-06},{"token":"B","logprob":-13.937071800231934},{"token":"C","logprob":-16.13436508178711},{"token":"Answer","logprob":-16.272348403930664},{"token":"No","logprob":-16.279769897460938},{"token":"None","logprob":-16.893823623657227},{"token":"N","logprob":-17.841047286987305},{"token":"D","logprob":-17.881547927856445},{"token":"The","logprob":-18.47382926940918},{"token":"\u0410","logprob":-18.662099838256836},{"token":"An","logprob":-18.709228515625},{"token":"F","logprob":-19.10689353942871},{"token":"a","logprob":-19.401803970336914},{"token":"Neither","logprob":-19.45448875427246},{"token":"I","logprob":-19.486284255981445},{"token":"W","logprob":-19.517179489135742},{"token":"H","logprob":-19.63551139831543},{"token":"E","logprob":-19.701650619506836},{"token":"P","logprob":-19.749990463256836},{"token":" A","logprob":-19.772314071655273}]}]}"#

  @Test func realSingleQuestionReplyIsABareObject() throws {
    let coffee = "The new coffee shop downtown opens at seven every day."
    let question = LearnedWordCheckQuestion(
      id: 21, sentence: coffee, range: coffee.range(of: "coffee")!,
      contextRange: coffee.startIndex..<coffee.endIndex, word: "Kaggle")
    let decision = try EGOneLearnedWordChecker.parseDecision(
      data: Data(Self.realSingleReply.utf8), question: question, threshold: 0.5)
    #expect(decision.questionID == 21)
    #expect(abs((decision.score ?? -1) - 8.855370908720138e-07) < 1e-12)
    #expect(decision.approved == false)
  }

  @Test func singleReplyRejectsArrayAndWrongIndex() {
    #expect(throws: EGOneLearnedWordChecker.CheckerError.self) {
      _ = try EGOneLearnedWordChecker.parseDecision(
        data: Data("[]".utf8), question: Self.question(), threshold: 0.5)
    }
    let wrongIndex = #"{"index":1,"completion_probabilities":[]}"#
    #expect(throws: EGOneLearnedWordChecker.CheckerError.self) {
      _ = try EGOneLearnedWordChecker.parseDecision(
        data: Data(wrongIndex.utf8), question: Self.question(), threshold: 0.5)
    }
  }

  @Test func polishBodyIsUnchangedWithoutAdapterAndDisablesLoadedAdapter() throws {
    let config = LLMProviderConfig(
      model: LLMProvider.egOneModelName, apiKeyKeychainId: nil,
      outputTokens: .capped(12), temperature: 0, thinking: nil)
    let baseline: [String: Any] = [
      "model": LLMProvider.egOneModelName,
      "messages": [
        ["role": "system", "content": "sys"],
        ["role": "user", "content": "text"],
      ],
      "max_tokens": 12,
      "temperature": 0,
    ]
    let absent = try EGOneConnector.makeRequestBody(
      system: "sys", user: "text", config: config, hasLearnedWordAdapter: false)
    #expect(
      try JSONSerialization.data(withJSONObject: baseline, options: .sortedKeys)
        == JSONSerialization.data(withJSONObject: absent, options: .sortedKeys))
    #expect(absent["lora"] == nil)
    #expect(absent["id_slot"] == nil)
    let loaded = try EGOneConnector.makeRequestBody(
      system: "sys", user: "text", config: config, hasLearnedWordAdapter: true)
    let lora = loaded["lora"] as? [[String: Any]]
    #expect(lora?.first?["id"] as? Int == 0)
    #expect(lora?.first?["scale"] as? Double == 0.0)
    #expect(loaded["id_slot"] as? Int == 0)
  }
}
