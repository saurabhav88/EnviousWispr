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
    let expected =
      "<|im_start|>system\n[Task: check] A word from the user's dictionary may have been misheard in a dictated sentence. A is the sentence as transcribed. B writes the dictionary word at one spot. Answer B only if the speaker meant the dictionary word there; otherwise answer A. Answer with one letter.<|im_end|>\n<|im_start|>user\nDictionary word: Tuist\nA: I said toast\nB: I said Tuist<|im_end|>\n<|im_start|>assistant\n"
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
    #expect(
      EGOneRuntime.launchArguments(for: .egOne, learnedWordAdapterURL: path)
        == baseline + ["--lora", path.path, "--lora-init-without-apply"])
    #expect(
      EGOneRuntime.launchArguments(for: .s1Mini, learnedWordAdapterURL: path)
        == EGOneRuntime.engineArguments(for: .s1Mini))
  }

  /// A real two-question reply from the bundled llama-server (EG-1 1.2 + checker adapter
  /// eg1c-v1, 2026-09-23), trimmed to the fields the parser reads and put in reverse order:
  /// the server tags each result with its prompt's `index`. Expected scores were computed
  /// from this reply by a separate Python reader, not by the parser under test.
  private static let realReply =
    #"[{"index":1,"completion_probabilities":[{"top_logprobs":[{"token":"A","logprob":-1.0609683158691041e-05},{"token":"B","logprob":-11.54736614227295},{"token":"C","logprob":-14.84553050994873},{"token":"Answer","logprob":-15.046477317810059},{"token":"No","logprob":-16.26599884033203},{"token":"The","logprob":-16.371965408325195},{"token":"None","logprob":-16.59360122680664},{"token":"D","logprob":-17.149703979492188},{"token":"An","logprob":-17.899316787719727},{"token":"N","logprob":-17.994251251220703},{"token":"\u0410","logprob":-18.271198272705078},{"token":"F","logprob":-18.349491119384766},{"token":"Neither","logprob":-18.57546043395996},{"token":"P","logprob":-18.660369873046875},{"token":"E","logprob":-18.68130874633789},{"token":"T","logprob":-18.705230712890625},{"token":"W","logprob":-18.817646026611328},{"token":"I","logprob":-19.03915786743164},{"token":"H","logprob":-19.052358627319336},{"token":"Not","logprob":-19.111757278442383}]}]},{"index":0,"completion_probabilities":[{"top_logprobs":[{"token":"A","logprob":-0.1656564325094223},{"token":"B","logprob":-1.880261778831482},{"token":"Answer","logprob":-10.11136531829834},{"token":"C","logprob":-10.360852241516113},{"token":"The","logprob":-12.160506248474121},{"token":"None","logprob":-12.316654205322266},{"token":"D","logprob":-12.843440055847168},{"token":"An","logprob":-13.176762580871582},{"token":"N","logprob":-13.229437828063965},{"token":"F","logprob":-13.394225120544434},{"token":"Assistant","logprob":-13.547582626342773},{"token":"No","logprob":-13.693490982055664},{"token":"E","logprob":-13.913171768188477},{"token":"Neither","logprob":-13.9204683303833},{"token":"P","logprob":-13.928181648254395},{"token":"W","logprob":-14.235458374023438},{"token":"O","logprob":-14.29381275177002},{"token":"H","logprob":-14.380805015563965},{"token":"In","logprob":-14.579191207885742},{"token":"I","logprob":-14.61187744140625}]}]}]"#

  @Test func realServerReplyBecomesComparableScoresMatchedByIndex() throws {
    let twist = "The day twist regenerated my whole Xcode project."
    let plot = "The plot twist surprised me."
    let questions = [
      LearnedWordCheckQuestion(
        id: 11, sentence: twist, range: twist.range(of: "twist")!, word: "Tuist"),
      LearnedWordCheckQuestion(
        id: 12, sentence: plot, range: plot.range(of: "twist")!, word: "Tuist"),
    ]
    let decisions = try EGOneLearnedWordChecker.parseDecisions(
      data: Data(Self.realReply.utf8), questions: questions, threshold: 0.1)
    #expect(decisions.map(\.questionID) == [11, 12])
    #expect(abs((decisions[0].score ?? -1) - 0.1525673348536626) < 1e-9)
    #expect(abs((decisions[1].score ?? -1) - 9.661465684240984e-06) < 1e-12)
    #expect(decisions.map(\.approved) == [true, false])
  }

  @Test func duplicateOrMissingIndexThrows() {
    let reply =
      #"[{"index":0,"completion_probabilities":[{"top_logprobs":[{"token":"A","logprob":-0.1}]}]},{"index":0,"completion_probabilities":[{"top_logprobs":[{"token":"B","logprob":-0.1}]}]}]"#
    #expect(throws: EGOneLearnedWordChecker.CheckerError.self) {
      _ = try EGOneLearnedWordChecker.parseDecisions(
        data: Data(reply.utf8), questions: [Self.question(), Self.question()], threshold: 0.5)
    }
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
    #expect(
      try JSONSerialization.data(withJSONObject: baseline, options: .sortedKeys)
        == JSONSerialization.data(withJSONObject: absent, options: .sortedKeys))
    #expect(absent["lora"] == nil)
    let loaded = try EGOneConnector.makeRequestBody(
      system: "sys", user: "text", config: config, hasLearnedWordAdapter: true)
    let lora = loaded["lora"] as? [[String: Any]]
    #expect(lora?.first?["id"] as? Int == 0)
    #expect(lora?.first?["scale"] as? Double == 0.0)
  }
}
