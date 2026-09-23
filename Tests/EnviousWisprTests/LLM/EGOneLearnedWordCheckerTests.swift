import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("EG-1 learned-word adapter wire contract (#3105)", .tags(.driftGuard))
struct EGOneLearnedWordCheckerTests {
  private static func question() -> LearnedWordCheckQuestion {
    let sentence = "I said toast"
    return LearnedWordCheckQuestion(
      id: 7, sentence: sentence, range: sentence.range(of: "toast")!, word: "Tuist")
  }

  @Test func trainedChatMLPromptIsPinned() {
    let expected = "<|im_start|>system\n[Task: check] A word from the user's dictionary may have been misheard in a dictated sentence. A is the sentence as transcribed. B writes the dictionary word at one spot. Answer B only if the speaker meant the dictionary word there; otherwise answer A. Answer with one letter.<|im_end|>\n<|im_start|>user\nDictionary word: Tuist\nA: I said toast\nB: I said Tuist<|im_end|>\n<|im_start|>assistant\n"
    #expect(EGOneLearnedWordChecker.prompt(for: Self.question()) == expected)
  }

  @Test func oneBatchRequestCarriesEveryPromptAndAdapterScale() {
    let checker = EGOneLearnedWordChecker(threshold: 0.5) { nil }
    #expect(checker.armName == "eg1_lora")
    #expect(checker.scoresAreComparable)
    let questions = [Self.question(), Self.question()]
    let body = EGOneLearnedWordChecker.makeRequestBody(questions)
    #expect((body["prompt"] as? [String])?.count == 2)
    #expect(body["n_predict"] as? Int == 1)
    #expect(body["n_probs"] as? Int == 20)
    #expect(body["temperature"] as? Int == 0)
    #expect(body["cache_prompt"] as? Bool == true)
    let lora = body["lora"] as? [[String: Any]]
    #expect(lora?.count == 1)
    #expect(lora?.first?["id"] as? Int == 0)
    #expect(lora?.first?["scale"] as? Double == 1.0)
  }

  @Test func adapterFlagsAreOnlyOnConfiguredEGOneLaunch() {
    let path = URL(fileURLWithPath: "/tmp/check.gguf")
    let baseline = EGOneRuntime.engineArguments(for: .egOne)
    #expect(EGOneRuntime.launchArguments(for: .egOne, learnedWordAdapterURL: nil) == baseline)
    #expect(EGOneRuntime.launchArguments(for: .egOne, learnedWordAdapterURL: path)
      == baseline + ["--lora", path.path, "--lora-init-without-apply"])
    #expect(EGOneRuntime.launchArguments(for: .s1Mini, learnedWordAdapterURL: path)
      == EGOneRuntime.engineArguments(for: .s1Mini))
  }

  @Test func firstTokenLogprobsBecomeComparableScore() throws {
    let data = Data(#"[{"probs":[{"top_logprobs":[{"token":"A","logprob":-1.6094379124341003},{"token":"B","logprob":-0.2231435513142097}]}]}]"#.utf8)
    let decisions = try EGOneLearnedWordChecker.parseDecisions(
      data: data, questions: [Self.question()], threshold: 0.75)
    #expect(decisions.count == 1)
    #expect(decisions[0].questionID == 7)
    #expect(decisions[0].approved)
    #expect(abs((decisions[0].score ?? 0) - 0.8) < 0.000001)
  }

  @Test func missingResultThrows() {
    #expect(throws: EGOneLearnedWordChecker.CheckerError.self) {
      _ = try EGOneLearnedWordChecker.parseDecisions(
        data: Data("[]".utf8), questions: [Self.question()], threshold: 0.5)
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
    #expect(try JSONSerialization.data(withJSONObject: baseline, options: .sortedKeys)
      == JSONSerialization.data(withJSONObject: absent, options: .sortedKeys))
    #expect(absent["lora"] == nil)
    let loaded = try EGOneConnector.makeRequestBody(
      system: "sys", user: "text", config: config, hasLearnedWordAdapter: true)
    let lora = loaded["lora"] as? [[String: Any]]
    #expect(lora?.first?["id"] as? Int == 0)
    #expect(lora?.first?["scale"] as? Double == 0.0)
  }
}
