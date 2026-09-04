import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

/// S1-mini pipeline routing (#2649). The sibling of `EGOnePipelineRoutingTests`,
/// and the rows that earn their place are the ones a single-model suite cannot
/// express: that the two engines resolve through SEPARATE handles, and that a
/// model which does not hold the server gets no polish rather than someone
/// else's.
@MainActor
@Suite("S1-mini pipeline routing (#2649)", .tags(.productOutcome))
struct S1MiniPipelineRoutingTests {

  private static let transcript =
    "so i was thinking we could maybe ship the new thing some time next week or so"

  /// Two plausible rewrites, differing only in a word the validator does not
  /// care about. That is what lets a row prove WHICH connector answered.
  private static let s1Answer =
    "I was thinking we could ship the new thing next week."
  private static let egOneAnswer =
    "I was thinking we could ship the new thing sometime next week."

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
    func polish(
      envelope: PromptEnvelope, config: LLMProviderConfig,
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

  private static func endpoint() -> EGOneEndpoint {
    EGOneEndpoint(port: 1, authToken: "t", contextTokens: 32768)
  }

  private func makeStep(
    s1Runtime: FakeRuntime?, egOneRuntime: FakeRuntime? = nil,
    polished: String = S1MiniPipelineRoutingTests.s1Answer
  ) -> LLMPolishStep {
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .s1Mini
    step.llmModel = LLMProvider.s1MiniModelName
    step.s1MiniRuntime = s1Runtime
    step.egOneRuntime = egOneRuntime
    step.makeS1MiniPolisher = { _ in CannedPolisher(output: polished) }
    // Deliberately a DIFFERENT output, so a row that ends up on EG-1's factory
    // is visible in the assertion rather than passing by coincidence. Both
    // strings are REALISTIC rewrites of the transcript: the output validator
    // rejects a result that diverges wildly from the input, so an obviously
    // fake marker would be discarded and every row would pass for the wrong
    // reason.
    step.makeEGOnePolisher = { _ in CannedPolisher(output: Self.egOneAnswer) }
    return step
  }

  private func run(_ step: LLMPolishStep, spy: CaptureSpy) async throws
    -> TextProcessingRunResult
  {
    let executor = FakeTimeoutExecutor(throwBelowSeconds: 0.0)
    let runner = TextProcessingRunner(
      telemetry: .init(
        captureError: spy.sink, recordPolishFailed: { _, _, _, _, _ in },
        recordPolishSkipped: TextProcessingRunner.TelemetrySeams.live.recordPolishSkipped),
      timeoutExecutor: executor.run)
    return try await runner.run(
      rawText: Self.transcript, evidence: .locked("en"), targetAppName: nil, steps: [step])
  }

  @Test("no S1-mini runtime handle means a silent raw fallback")
  func missingRuntimeIsSilent() async throws {
    let spy = CaptureSpy()
    let result = try await run(makeStep(s1Runtime: nil), spy: spy)
    #expect(result.polishError == nil)
    #expect(spy.count == 0)
    #expect(result.context.text == Self.transcript)
    #expect(result.context.polishedText == nil)
  }

  /// THE row this suite exists for. EG-1 holds the server, so the coordinator
  /// returns nil for S1-mini and its runtime reports no endpoint. The user must
  /// get their own words back, never EG-1's rewrite labelled as S1-mini's.
  @Test("another model holding the server means no polish, never the wrong one")
  func nonResidentModelGetsNoPolish() async throws {
    let spy = CaptureSpy()
    let step = makeStep(
      s1Runtime: FakeRuntime(endpoint: nil),          // coordinator refused it
      egOneRuntime: FakeRuntime(endpoint: Self.endpoint()))  // EG-1 is resident
    let result = try await run(step, spy: spy)

    #expect(result.context.polishedText == nil)
    #expect(result.context.text == Self.transcript)
    #expect(
      result.context.polishedText != Self.egOneAnswer,
      "a polish must never be served by another model's weights")
    #expect(spy.count == 0, "an unavailable local limb is a silent bypass")
  }

  @Test("a live endpoint routes to the S1-mini connector, not EG-1's")
  func liveEndpointUsesItsOwnConnector() async throws {
    let spy = CaptureSpy()
    let step = makeStep(
      s1Runtime: FakeRuntime(endpoint: Self.endpoint()),
      egOneRuntime: FakeRuntime(endpoint: Self.endpoint()),
      polished: Self.s1Answer)
    let result = try await run(step, spy: spy)

    #expect(result.context.polishedText == Self.s1Answer)
    #expect(result.context.polishedText != Self.egOneAnswer)
    #expect(spy.count == 0)
  }
}
