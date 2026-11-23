import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #4471 Guard 3 (`question_flip`): CJK full-width question mark (`？`, U+FF1F) is equivalent
/// to ASCII `?` in both directions across both `.ordinary` and `.batchPiece` policies, while
/// dropping both still triggers `question_flip`.
@Suite(.tags(.productOutcome))
@MainActor
struct PolishQuestionGuardTests {

  private let step = LLMPolishStep(
    keychainManager: KeychainManager(), localPolishers: .llamaForTests)

  private func validate(
    _ polished: String,
    original: String,
    provider: LLMProvider = .egOne,
    policy: LLMPolishStep.ResultPolicy = .ordinary
  ) -> LLMPolishStep.PolishValidation {
    step.validatePolishOutput(
      polished: polished, original: original, mode: .message,
      provider: provider, model: "eg-1", policy: policy)
  }

  @Test("ASCII question mark polished to full-width question mark stands (#4471)")
  func asciiQuestionToFullWidthQuestionStands() {
    let original = "嗯,那个,郭佳,咱们开场前先对一下灯光,OK?"
    let polished = "郭佳，咱们开场前先对一下灯光，OK？"
    for policy in [LLMPolishStep.ResultPolicy.ordinary, .batchPiece] {
      let result = validate(polished, original: original, policy: policy)
      #expect(result.guardName == nil)
      #expect(result.text == polished)
    }
  }

  @Test("Full-width question mark polished to ASCII or retained stands (#4471)")
  func fullWidthQuestionSymmetricAndRetained() {
    let original = "这个可以吗？"
    for policy in [LLMPolishStep.ResultPolicy.ordinary, .batchPiece] {
      let toASCII = validate("这个可以吗?", original: original, policy: policy)
      #expect(toASCII.guardName == nil)
      #expect(toASCII.text == "这个可以吗?")

      let retained = validate("这个可以吗？", original: original, policy: policy)
      #expect(retained.guardName == nil)
      #expect(retained.text == "这个可以吗？")
    }
  }

  @Test("Full-width question turned into statement triggers question_flip on both policies")
  func fullWidthQuestionDroppedTriggersGuard() {
    let original = "这个可以吗？"
    for policy in [LLMPolishStep.ResultPolicy.ordinary, .batchPiece] {
      let result = validate("这个可以。", original: original, policy: policy)
      #expect(result.guardName == "question_flip")
      #expect(result.text == original)
    }
  }
}
