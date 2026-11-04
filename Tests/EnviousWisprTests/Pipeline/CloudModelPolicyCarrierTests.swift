import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

/// #4353 D6: the cloud model list an operation captured reaches its request policy: import
/// parts and batches, recovery replay, discovery filtering and the warm-up body.
///
/// When this fails, a polish request is built from a list the operation never captured (or
/// from no list), so a model is sent the wrong thinking value, batched when it must not be, or
/// hidden from the menu.
@MainActor
@Suite("Cloud model list carriers (#4353)", .tags(.productOutcome))
struct CloudModelPolicyCarrierTests {

  /// One OpenAI row per policy under test, each the opposite of the compiled fallback.
  static let list: CloudModelList = {
    let data = Data(
      #"{"schema":1,"updated":"2026-11-04","models":[{"provider":"openAI","id":"gpt-4o-mini","recommended":false,"hidden":false,"request":{"openAIEffort":"omit","temperature":"include"},"supportsChatCompletions":true,"allowsFileBatch":true},{"provider":"openAI","id":"gpt-6-locked","recommended":false,"hidden":false,"request":{"openAIEffort":"low","temperature":"omit"},"supportsChatCompletions":false,"allowsFileBatch":false},{"provider":"claude","id":"claude-new","recommended":false,"hidden":false,"request":{"claudeShape":"effortLow"},"supportsChatCompletions":false,"allowsFileBatch":true}]}"#
        .utf8)
    guard case .success(let list) = CloudModelList.validated(from: data) else {
      preconditionFailure("fixture list is invalid")
    }
    return list
  }()

  static let settings = RecordingSettingsSnapshot(
    backendType: .parakeet, backendSupportsLanguageDetection: false,
    languageMode: .auto, wordCorrectionEnabled: false, fillerRemovalEnabled: false,
    emojiFormatterEnabled: false, spokenPunctuationEnabled: false, spokenPunctuationStartWords: nil,
    spokenPunctuationEnglishPeriodWord: nil,
    llmProvider: LLMProvider.openAI.rawValue, llmModel: "gpt-4o-mini", s1Control: nil,
    englishSpelling: nil, casualModeEnabled: nil)

  static func batchContext() -> TextProcessingContext {
    var context = TextProcessingContext(
      text: "So we agreed to move the launch to Friday and tell the whole team today.",
      language: "en")
    context.languageSource = .locked
    return context
  }

  @Test("every part of an import polishes under the list frozen with its settings")
  func importPartsCarryTheFrozenList() {
    let runner = FileImportRunner(keychainManager: KeychainManager())
    runner.freeze(settings: Self.settings, vocabulary: nil, cloudModelList: Self.list)
    let first = runner.makeSteps(settings: Self.settings).llmPolish
    let second = runner.makeSteps(settings: Self.settings).llmPolish
    #expect(first.cloudModelList?.revision == Self.list.revision)
    #expect(second.cloudModelList?.revision == Self.list.revision)

    runner.freeze(settings: Self.settings, vocabulary: nil, cloudModelList: nil)
    #expect(runner.makeSteps(settings: Self.settings).llmPolish.cloudModelList == nil)
  }

  @Test("file batching follows the captured list's row, and the fallback without one")
  func batchingFollowsTheCapturedList() {
    let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini-2024-07-18"
    // No list: the compiled #2905 fallback keeps GPT-4o mini (and its dated copies) ordinary.
    #expect(step.fileBatchMember(Self.batchContext()) == nil)
    // The list says this model may batch: the dated copy inherits its base row.
    step.cloudModelList = Self.list
    #expect(step.fileBatchMember(Self.batchContext()) != nil)
    // A listed false keeps an id ordinary although the fallback would batch it.
    step.llmModel = "gpt-6-locked"
    #expect(step.fileBatchMember(Self.batchContext()) == nil)
  }

  @Test("a recovered take polishes under the list its replay captured, whatever the spool says")
  func recoveryUsesTheReplayList() {
    let processor = RecoveryTextProcessor(
      keychainManager: KeychainManager(), cloudModelList: Self.list)
    processor.applySettings(Self.settings)
    #expect(processor.llmPolishStep.cloudModelList?.revision == Self.list.revision)
    #expect(processor.llmPolishStep.llmModel == "gpt-4o-mini")
  }

  @Test("discovery hides an id its captured list marks as not chat-capable")
  func discoveryFiltersByTheCapturedList() {
    let models: [[String: Any]] = [["id": "gpt-6-locked", "created": 1_780_000_000]]
    #expect(LLMModelDiscovery.openAICandidates(fromModels: models, list: nil).count == 1)
    #expect(LLMModelDiscovery.openAICandidates(fromModels: models, list: Self.list).isEmpty)
  }

  @Test("the Claude warm-up body takes its shape from the warm-up's captured list")
  func warmupUsesTheCapturedList() throws {
    func body(_ list: CloudModelList?) throws -> [String: Any] {
      let request = try #require(
        LLMNetworkSession.shared.buildWarmupRequest(
          provider: .claude, model: "claude-new", apiKey: "k", cloudModelList: list))
      let data = try #require(request.httpBody)
      return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    let listed = try body(Self.list)
    #expect(listed["thinking"] == nil)
    #expect((listed["output_config"] as? [String: String]) == ["effort": "low"])
    let unlisted = try body(nil)
    #expect((unlisted["thinking"] as? [String: String]) == ["type": "disabled"])
  }
}
