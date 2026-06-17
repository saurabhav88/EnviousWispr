import EnviousWisprCore
import EnviousWisprLLM
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

  @Test("AFM context-window overflow (predicted) is a SILENT skip: raw text, no polishError")
  func contextWindowPredictedIsSilentSkip() async throws {
    let runner = TextProcessingRunner()
    let raw = "raw asr transcript that exceeds the on-device window"
    let skip = ContextWindowSkipStep(stage: .predicted)

    let result = try await runner.run(
      rawText: raw, language: nil, targetAppName: nil, steps: [skip])

    // Heart contract: raw text survives.
    #expect(result.context.text == raw)
    #expect(result.context.polishedText == nil)
    // #1055: a too-long dictation is a clean skip, NOT a failure — it must NOT
    // surface "AI polish failed" (contrast `polishFailureFallsBackToRaw`).
    #expect(result.polishError == nil)
  }

  @Test("AFM context-window overflow (caught) is also a silent skip")
  func contextWindowCaughtIsSilentSkip() async throws {
    let runner = TextProcessingRunner()
    let raw = "raw asr transcript"
    let skip = ContextWindowSkipStep(stage: .caught)

    let result = try await runner.run(
      rawText: raw, language: nil, targetAppName: nil, steps: [skip])

    #expect(result.context.text == raw)
    #expect(result.context.polishedText == nil)
    #expect(result.polishError == nil)
  }

  @Test("Apple Intelligence polish TIMEOUT is a SILENT skip: raw text, no polishError")
  func appleIntelligencePolishTimeoutIsSilentSkip() async throws {
    // #1055: the appleIntelligence budget is 10s; `throwBelowSeconds: 999`
    // forces the executor to throw TimeoutError without ever invoking the step,
    // simulating the on-device model stalling on a long dictation. A real
    // LLMPolishStep is required (not a fake) because the runner scopes the
    // silent-timeout behavior via `as? LLMPolishStep`'s `llmProvider`.
    let fakeTimeout = FakeTimeoutExecutor(throwBelowSeconds: 999)
    let runner = TextProcessingRunner(timeoutExecutor: fakeTimeout.run)
    let raw = "raw asr transcript from a long dictation"
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .appleIntelligence

    let result = try await runner.run(
      rawText: raw, language: nil, targetAppName: nil, steps: [step])

    // The on-device model stalled, but a too-long dictation isn't a failure —
    // raw deterministically-cleaned text ships and NO "AI polish failed"
    // surfaces (contrast `cloudPolishTimeoutSurfacesError`).
    #expect(result.context.text == raw)
    #expect(result.context.polishedText == nil)
    #expect(result.polishError == nil)
    #expect(fakeTimeout.callCount == 1)  // op short-circuited; step never ran
  }

  @Test("A cloud-provider polish timeout STILL surfaces polishError (contrast with AFM)")
  func cloudPolishTimeoutSurfacesError() async throws {
    // #1055: the timeout silence is scoped to appleIntelligence ONLY. A cloud
    // (OpenAI) timeout signals a transient network issue the user should see,
    // so it must continue to surface as "AI polish failed".
    let fakeTimeout = FakeTimeoutExecutor(throwBelowSeconds: 999)
    let runner = TextProcessingRunner(timeoutExecutor: fakeTimeout.run)
    let raw = "raw asr transcript"
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .openAI

    let result = try await runner.run(
      rawText: raw, language: nil, targetAppName: nil, steps: [step])

    #expect(result.context.text == raw)
    #expect(result.context.polishedText == nil)
    #expect(result.polishError != nil)
  }

  @Test("AFM timeout stays silent even if the provider is switched mid-polish (torn-read guard)")
  func afmTimeoutSilentDespiteMidFlightProviderSwitch() async throws {
    // #1055 (Codex review): the runner must classify the timeout by the provider
    // the polish STARTED with, not the live (possibly-mutated) `llmProvider`.
    // PipelineSettingsSync can switch providers during an in-flight polish; that
    // must NOT flip an Apple Intelligence timeout into a surfaced "AI polish
    // failed". The executor here mutates the provider to a cloud value and THEN
    // times out, simulating that race.
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .appleIntelligence
    let runner = TextProcessingRunner(timeoutExecutor: { _, _ in
      step.llmProvider = .openAI  // settings change during the suspended polish
      throw TimeoutError(seconds: 10)
    })
    let raw = "raw asr transcript"

    let result = try await runner.run(
      rawText: raw, language: nil, targetAppName: nil, steps: [step])

    // RED before the snapshot fix (catch read the now-.openAI live value →
    // surfaced); GREEN after (snapshot-at-start is .appleIntelligence → silent).
    #expect(result.context.text == raw)
    #expect(result.context.polishedText == nil)
    #expect(result.polishError == nil)
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

/// #1055 test double: a polish step that throws `AFMContextWindowExceeded`
/// (the too-long-for-on-device signal). Name matches the production step so the
/// runner's `errorSurfacePolicy` dispatch applies; the runner must treat this
/// throw as a SILENT skip (no `polishError`), unlike a generic limb failure.
@MainActor
private final class ContextWindowSkipStep: TextProcessingStep {
  let name = "LLM Polish"
  let isEnabled = true
  let maxDuration: Duration = .seconds(60)
  let errorSurfacePolicy: ErrorSurfacePolicy = .surface
  private let stage: AFMContextWindowExceeded.Stage

  init(stage: AFMContextWindowExceeded.Stage) {
    self.stage = stage
  }

  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    throw AFMContextWindowExceeded(stage: stage)
  }
}
