import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

/// EG-1 native pipeline routing + silent-skip contract (#1271):
/// - `.egOne` resolves through `egOneRuntime` (never the keychain factory);
/// - every unavailability is a SILENT bypass (no polish error, no capture,
///   raw text preserved, no provider stamp);
/// - a healthy endpoint routes to the EG-1 polisher and stamps normally;
/// - context preflight skips whole (never truncates);
/// - retry policy treats EG-1 skips as non-retryable.
@MainActor
@Suite("EG-1 pipeline routing (#1271)")
struct EGOnePipelineRoutingTests {

  private static let longTranscript =
    "so i was thinking we could maybe ship the new thing some time next week or so"

  @MainActor
  final class FakeRuntime: EGOneEndpointProviding {
    var endpoint: EGOneEndpoint?
    init(endpoint: EGOneEndpoint? = nil) { self.endpoint = endpoint }
    func activeEndpoint() async -> EGOneEndpoint? { endpoint }
  }

  private struct CannedPolisher: TranscriptPolisher {
    let output: String
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      LLMResult(polishedText: output)
    }
  }

  @MainActor
  final class CaptureSpy {
    private(set) var count = 0
    func sink(
      _ error: any Error, _ category: SentryBreadcrumb.ErrorCategory,
      _ stage: String, _ extra: [String: Any]?, _ tags: [String: String],
      _ fingerprintDetail: String?
    ) { count += 1 }
  }

  private func makeStep(runtime: FakeRuntime?) -> LLMPolishStep {
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .egOne
    step.llmModel = LLMProvider.egOneModelName
    step.egOneRuntime = runtime
    return step
  }

  private func run(_ step: LLMPolishStep, spy: CaptureSpy) async throws
    -> TextProcessingRunResult
  {
    let executor = FakeTimeoutExecutor(throwBelowSeconds: 0.0)
    // EG-1 bypasses fire no capture and no failure record; they DO emit a
    // `llm.polish_skipped`, so that seam stays live. The failure seam is no-op'd
    // so this suite can never reach the real PostHog failure client (#1446).
    let runner = TextProcessingRunner(
      telemetry: .init(
        captureError: spy.sink, recordPolishFailed: { _, _, _, _ in },
        // This suite asserts on the real `llm.polish_skipped` via testEventHook.
        recordPolishSkipped: TextProcessingRunner.TelemetrySeams.live.recordPolishSkipped),
      timeoutExecutor: executor.run)
    return try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])
  }

  // MARK: - Silent bypasses

  @Test("no runtime handle -> silent raw fallback, no capture, no stamp")
  func missingRuntimeIsSilent() async throws {
    let spy = CaptureSpy()
    let result = try await run(makeStep(runtime: nil), spy: spy)
    #expect(result.polishError == nil)
    #expect(spy.count == 0)
    #expect(result.context.text == Self.longTranscript)
    #expect(result.context.polishedText == nil)
    #expect(result.context.llmProvider == nil)
  }

  @Test("runtime present but server not ready -> silent raw fallback")
  func notReadyEndpointIsSilent() async throws {
    let spy = CaptureSpy()
    let result = try await run(makeStep(runtime: FakeRuntime(endpoint: nil)), spy: spy)
    #expect(result.polishError == nil)
    #expect(spy.count == 0)
    #expect(result.context.polishedText == nil)
  }

  @Test("input over context budget -> silent whole-skip, never truncation")
  func overBudgetInputSkipsWhole() async throws {
    let spy = CaptureSpy()
    // Tiny context window: the 16-word transcript over-budgets it.
    let runtime = FakeRuntime(
      endpoint: EGOneEndpoint(port: 1, authToken: "t", contextTokens: 16))
    let step = makeStep(runtime: runtime)
    step.makeEGOnePolisher = { _ in CannedPolisher(output: "MUST NOT BE USED") }
    let result = try await run(step, spy: spy)
    #expect(result.polishError == nil)
    #expect(result.context.polishedText == nil)
    #expect(result.context.text == Self.longTranscript)
  }

  // MARK: - Healthy path

  @Test("ready endpoint routes to EG-1 polisher and stamps provider")
  func healthyEndpointPolishes() async throws {
    let spy = CaptureSpy()
    let runtime = FakeRuntime(
      endpoint: EGOneEndpoint(port: 1, authToken: "t", contextTokens: 32768))
    let step = makeStep(runtime: runtime)
    step.makeEGOnePolisher = { endpoint in
      #expect(endpoint.authToken == "t")
      return CannedPolisher(output: "I was thinking we could ship the new thing next week.")
    }
    let result = try await run(step, spy: spy)
    #expect(result.polishError == nil)
    #expect(
      result.context.polishedText == "I was thinking we could ship the new thing next week.")
    #expect(result.context.llmProvider == LLMProvider.egOne.rawValue)
    #expect(result.context.llmModel == LLMProvider.egOneModelName)
  }

  @Test("keychain factory is never consulted for .egOne")
  func keychainFactoryNotUsed() async throws {
    let spy = CaptureSpy()
    let runtime = FakeRuntime(
      endpoint: EGOneEndpoint(port: 1, authToken: "t", contextTokens: 32768))
    let step = makeStep(runtime: runtime)
    var legacyFactoryCalled = false
    step.makePolisher = { _, _, _ in
      legacyFactoryCalled = true
      return nil
    }
    step.makeEGOnePolisher = { _ in CannedPolisher(output: "ok output text") }
    _ = try await run(step, spy: spy)
    #expect(!legacyFactoryCalled)
  }

  // MARK: - Contract lookalikes must NOT be silent

  @Test("a genuine surfaced error family still surfaces for cloud providers")
  func cloudErrorsStillSurface() async throws {
    // Guard against over-widening the silent set: an Ollama provider-down
    // error must still surface (adversarial pairing for the new branch).
    let spy = CaptureSpy()
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .ollama
    step.llmModel = "llama3.2"
    // #1305: report ready so this stays a MID-FLIGHT surfacing test (the
    // preflight gate would otherwise intercept, and would probe a real socket).
    step.ollamaReadinessProbe = { _ in .ready }
    struct Down: TranscriptPolisher {
      func polish(
        text: String, instructions: PolishInstructions, config: LLMProviderConfig,
        onToken: (@Sendable (String) -> Void)?
      ) async throws -> LLMResult { throw LLMError.providerUnavailable }
    }
    step.makePolisher = { _, _, _ in Down() }
    let result = try await run(step, spy: spy)
    #expect(result.polishError != nil)
  }

  // MARK: - Retry policy

  @Test("egOneSkipped is explicitly non-retryable")
  func egOneSkipsAreNotRetryable() {
    #expect(!LLMRetryPolicy.isRetryable(LLMError.egOneSkipped(.crashed)))
    #expect(!LLMRetryPolicy.isRetryable(LLMError.egOneSkipped(.notReady)))
    #expect(!LLMRetryPolicy.isRetryable(LLMError.egOneSkipped(.downloadPending)))
    #expect(!LLMRetryPolicy.isRetryable(LLMError.egOneSkipped(.inputTooLong)))
  }

  // MARK: - Planner routing

  @Test("planner maps .egOne to the egOneFixed family regardless of model id")
  func plannerRoutesEGOne() {
    #expect(DefaultPromptPlanner.family(for: .egOne, modelID: "eg-1") == .egOneFixed)
    #expect(DefaultPromptPlanner.family(for: .egOne, modelID: "anything") == .egOneFixed)
  }

  @Test("skip reasons carry the local_polish_ telemetry prefix")
  func skipReasonPrefixes() {
    for reason in [
      EGOneSkipReason.notReady, .downloadPending, .crashed, .inputTooLong, .outputTruncated,
    ] {
      #expect(PolishSkipReason.egOne(reason).telemetryTag.hasPrefix("local_polish_"))
    }
  }
}
