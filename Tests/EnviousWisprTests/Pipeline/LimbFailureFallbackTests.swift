import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// PR-4b.4 of #827 — heart/limbs contract: when the LLM polish limb throws,
/// the heart still delivers raw ASR text. The runner surfaces the polish
/// error as `polishError`, leaves `polishedText` nil, and the unmodified raw
/// text remains in `context.text` for the kernel to persist + paste.
///
/// Forces failure via a fake step named `"LLM Polish"` (matching the
/// production polish step's `name`) with `errorSurfacePolicy == .surface`
/// so the runner routes its throw to the user-visible error channel.
/// The earlier-limb steps (word correction / filler removal / emoji
/// formatter) are omitted — irrelevant to the polish-failure question and
/// keeps the test focused.
@Suite("Limb failure fallback (polish throws → raw ASR delivered)")
@MainActor
struct LimbFailureFallbackTests {

  @Test("Polish step throw leaves raw text intact and surfaces polishError")
  func polishFailureFallsBackToRaw() async throws {
    let runner = TextProcessingRunner()
    let raw = "raw asr transcript"
    let failing = FailingPolishStep(message: "Polish failed -- test failure")

    let result = try await runner.run(
      rawText: raw,
      language: nil,
      targetAppName: nil,
      steps: [failing]
    )

    // Heart contract: raw text survives even though polish threw.
    #expect(result.context.text == raw)
    #expect(result.context.polishedText == nil)
    // Polish-failure surface: the error message reaches the caller so the
    // overlay can show "Polish failed -- using raw text".
    #expect(result.polishError == "Polish failed -- test failure")
  }

  @Test("Polish disabled (isEnabled=false) skips the step without error")
  func polishDisabledSkipsCleanly() async throws {
    let runner = TextProcessingRunner()
    let raw = "raw asr transcript"
    let disabled = FailingPolishStep(message: "Should not fire", isEnabled: false)

    let result = try await runner.run(
      rawText: raw,
      language: nil,
      targetAppName: nil,
      steps: [disabled]
    )

    #expect(result.context.text == raw)
    #expect(result.context.polishedText == nil)
    // Disabled step never ran → no error surfaced.
    #expect(result.polishError == nil)
  }
}

/// Test double conforming to the package-internal `TextProcessingStep`
/// protocol. Name matches the production step ("LLM Polish") so the runner's
/// `errorSurfacePolicy` dispatch routes failures to `polishError`.
@MainActor
private final class FailingPolishStep: TextProcessingStep {
  let name = "LLM Polish"
  let isEnabled: Bool
  // Generous timeout: the runner races `process()` against this deadline.
  // On contended CI (Apple M1 Virtual, 3 cores), MainActor scheduling delay
  // beat a 5s deadline on the post-merge run of a5a2eec, causing the timeout
  // to surface before the deterministic throw. The test asserts behavior on
  // the throw, not on the timeout — make the deadline unreachable in practice.
  let maxDuration: Duration = .seconds(60)
  let errorSurfacePolicy: ErrorSurfacePolicy = .surface
  private let message: String

  init(message: String, isEnabled: Bool = true) {
    self.message = message
    self.isEnabled = isEnabled
  }

  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    throw FailingPolishError(message: message)
  }
}

private struct FailingPolishError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
