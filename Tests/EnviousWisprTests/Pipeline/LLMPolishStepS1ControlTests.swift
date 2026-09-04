import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// The polish step is the ONE producer of `PromptBuildInput` on the live path
/// (#2649). Its `s1Control` field is defaulted, so a step that never forwarded
/// the user's picks would compile, pass every default-valued test, and send
/// every user the shipped tone whatever they chose. When this fails, the user
/// picks Formal and gets semi-formal with nothing saying why.
@MainActor
@Suite("LLMPolishStep forwards the S1-mini picks (#2649)", .tags(.productOutcome))
struct LLMPolishStepS1ControlTests {

  /// Records the input the step handed the planner, then plans for real so the
  /// step continues down its ordinary path.
  private final class PlannerCapture: @unchecked Sendable {
    var input: PromptBuildInput?
  }

  private struct CapturingPlanner: PromptPlanning {
    let capture: PlannerCapture
    func plan(input: PromptBuildInput) -> PolishPlan {
      capture.input = input
      return DefaultPromptPlanner().plan(input: input)
    }
  }

  private struct FixedPolisher: TranscriptPolisher {
    let result: String
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      LLMResult(polishedText: result)
    }
  }

  // Long enough to clear the short-transcript short-circuit and pass the
  // similar-length polish validator.
  private static let spoken = "so um i need to send the quarterly report to sarah by friday morning"
  private static let polished = "So I need to send the quarterly report to Sarah by Friday morning."

  @Test("the configured picks are the ones the planner receives")
  func picksReachThePlanner() async throws {
    let picks = S1ControlSettings(styling: .formal, structure: .prose, context: .email)
    #expect(picks != .default, "a default-valued pick could not show the forward happened")

    let step = LLMPolishStep(keychainManager: KeychainManager())
    // `.openAI` only selects that provider's budget and enables the step; the
    // injected polisher replaces the connector, so no key or network is used.
    // The forward under test is provider-independent: the step hands the
    // planner ONE input whatever the engine.
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"
    step.s1Control = picks
    let capture = PlannerCapture()
    step.promptPlanner = CapturingPlanner(capture: capture)
    step.makePolisher = { _, _, _ in FixedPolisher(result: Self.polished) }

    _ = try await step.process(TextProcessingContext(text: Self.spoken, language: nil))

    let input = try #require(capture.input)
    #expect(input.s1Control == picks)
  }

  /// The planner filters vocabulary through `withPolishVocabulary`, which
  /// rebuilds the input field by field and silently drops any field it does
  /// not name. This is the one seam where the picks could vanish AFTER the
  /// step forwarded them, so it is asserted on the rebuilt value directly.
  @Test("the planner's field-by-field rebuild keeps the picks")
  func rebuildKeepsThePicks() {
    let picks = S1ControlSettings(styling: .casual, structure: .prose, context: .email)
    let input = PromptBuildInput(
      transcript: Self.spoken, provider: .s1Mini, modelID: LLMProvider.s1MiniModelName,
      appName: nil, language: nil, polishVocabulary: .empty, s1Control: picks)
    let rebuilt = input.withPolishVocabulary(PolishVocabulary(terms: [], generation: 1))
    #expect(rebuilt.s1Control == picks)
  }
}
