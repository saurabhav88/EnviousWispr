import MLX
import Testing

@testable import EnviousWisprWordCheck

@Suite("Kev scoring error stays catchable", .tags(.productOutcome))
struct KevScoringErrorTests {
  @Test("an MLX scoring graph error throws and the process survives")
  func invalidArrayDoesNotEndProcess() throws {
    let compiled = compile { (input: MLXArray) -> MLXArray in
      input + MLXArray([Float(1), 1, 1])
    }
    let input = MLXArray([Float(0), 0])
    #expect(throws: KevWordCheckModel.ScoringError.mlxEvaluation) {
      _ = try KevWordCheckModel.checkedRead { compiled(input) }
    }
  }
}
