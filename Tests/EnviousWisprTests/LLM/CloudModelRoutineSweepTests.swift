import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #4353 PR 5 (D7 detail, Stage 1 execution): the weekly cloud model routine's real run.
///
/// PAID and networked: it reads the three providers' catalogs and polishes three real
/// dictations per new model with the routine's own keys. It runs only in the scheduled
/// maintenance workflow:
/// `TEST_RUNNER_EW_CLOUD_ROUTINE=1 scripts/xcode-test.sh --real-boundary --filter EnviousWisprTests/CloudModelRoutineSweepTests`
/// with `TEST_RUNNER_EW_ROUTINE_{OPENAI,CLAUDE,GEMINI}_KEY` set. The output is a file,
/// `EW_ROUTINE_RECEIPT_OUT` (required). The receipt is written only after a secret scan;
/// nothing here prints a key, prompt or reply.
@Suite(
  "Cloud model routine weekly sweep (#4353 PR 5)",
  .tags(.harnessContract, .realBoundary),
  .enabled(if: ProcessInfo.processInfo.environment["EW_CLOUD_ROUTINE"] == "1"),
  .realBoundaryRun)
struct CloudModelRoutineSweepTests {

  enum RunFailure: Error, CustomStringConvertible {
    case missingKeys([String])
    case missingReceiptPath
    case unreadableList

    var description: String {
      switch self {
      case .missingKeys(let names): return "missing routine keys: \(names.joined(separator: ", "))"
      case .missingReceiptPath: return "EW_ROUTINE_RECEIPT_OUT is not set"
      case .unreadableList: return "the committed model list did not validate"
      }
    }
  }

  @Test(.timeLimit(.minutes(30)))
  func weeklySweep() async throws {
    let environment = ProcessInfo.processInfo.environment
    let keys: CloudModelRoutine.Keys
    switch CloudModelRoutine.Keys.from(environment: environment) {
    case .success(let found): keys = found
    case .failure(let missing): throw RunFailure.missingKeys(missing.variables.map(\.rawValue))
    }
    guard let receiptPath = environment["EW_ROUTINE_RECEIPT_OUT"], !receiptPath.isEmpty else {
      throw RunFailure.missingReceiptPath
    }
    guard let list = try? CloudModelListSeed.list() else { throw RunFailure.unreadableList }

    let receipt = await CloudModelRoutine.run(
      keys: keys, list: list, observedAt: Date(), transports: .live,
      provenance: .from(environment: environment))
    let data = try receipt.encoded(refusing: Array(keys.values.values))
    try data.write(to: URL(fileURLWithPath: receiptPath), options: .atomic)
    print(
      "cloud-model-routine outcome=\(receipt.outcome) logical=\(receipt.logicalCalls) physical=\(receipt.physicalExchanges)"
    )
  }
}
