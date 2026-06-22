import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #945: the runner's classify -> composed-notice + telemetry path. These run a
/// REAL `LLMPolishStep` (with an injected throwing polisher) through the runner,
/// because the capture/compose path only fires for an actual polish step — the
/// runner snapshots `(step as? LLMPolishStep)?.llmProvider/.llmModel` to know the
/// provider and to exclude Apple Intelligence. A bare spy step has no provider,
/// so the existing `TextProcessingRunnerTests` (which use bare spies) keep their
/// legacy raw-message assertions and live in that suite.
@MainActor
@Suite("TextProcessingRunner telemetry + composed notice")
struct TextProcessingRunnerCaptureTests {

  /// A 16-word sentence that clears the polish step's <=3-word short-circuit
  /// (LLMPolishStep.minWordsForPolish) so the injected polisher actually runs.
  private static let longTranscript =
    "so i was thinking we could maybe ship the new thing some time next week or so"

  /// Records every runner capture so a test can assert exactly one fired with the
  /// right reason tag, provider, and metadata.
  @MainActor
  final class CaptureSpy {
    struct Call {
      let category: SentryBreadcrumb.ErrorCategory
      let stage: String
      let extra: [String: Any]?
      let tags: [String: String]
      let fingerprintDetail: String?
    }
    private(set) var calls: [Call] = []
    func sink(
      _ error: any Error, _ category: SentryBreadcrumb.ErrorCategory,
      _ stage: String, _ extra: [String: Any]?, _ tags: [String: String],
      _ fingerprintDetail: String?
    ) {
      calls.append(
        Call(
          category: category, stage: stage, extra: extra, tags: tags,
          fingerprintDetail: fingerprintDetail))
    }
  }

  /// Polisher that always throws the supplied error. Implements only the legacy
  /// `text:` method; the planner path reaches it via the protocol's default
  /// `envelope:` bridge (same pattern as the reentrancy suite).
  private struct ThrowingPolisher: TranscriptPolisher {
    let makeError: @Sendable () -> any Error
    func polish(
      text: String,
      instructions: PolishInstructions,
      config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      throw makeError()
    }
  }

  private func makeStep(
    provider: LLMProvider,
    model: String,
    throwing makeError: @escaping @Sendable () -> any Error
  ) -> LLMPolishStep {
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = provider
    step.llmModel = model
    step.makePolisher = { _, _, _ in ThrowingPolisher(makeError: makeError) }
    return step
  }

  private func makeRunner(_ spy: CaptureSpy) -> TextProcessingRunner {
    // throwBelowSeconds 0.0 -> the executor runs every step (never injects a
    // timeout); the polisher's own throw drives the failure.
    let executor = FakeTimeoutExecutor(throwBelowSeconds: 0.0)
    return TextProcessingRunner(captureError: spy.sink, timeoutExecutor: executor.run)
  }

  // MARK: - Cloud / local classified failures

  @Test("cloud rejected key -> 'rejected' notice + api_key_rejected tag (one capture)")
  func cloudKeyRejected() async throws {
    let spy = CaptureSpy()
    let runner = makeRunner(spy)
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") { LLMError.invalidAPIKey }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(
      result.polishError
        == "AI polish failed: OpenAI rejected your API key. Check or replace it in Settings.")
    #expect(spy.calls.count == 1)
    let call = try #require(spy.calls.first)
    #expect(call.category == .polishProviderFailed)
    #expect(call.stage == "polish")
    #expect(call.tags["polish.error_case"] == "api_key_rejected")
    #expect(call.tags["polish.provider"] == "openAI")
    #expect(call.tags["polish.is_timeout"] == "false")
    #expect(call.extra?["provider"] as? String == "openAI")
    #expect(call.extra?["model"] as? String == "gpt-4o-mini")
    // #945: the reason also splits the Sentry issue (fingerprint discriminator).
    #expect(call.fingerprintDetail == "api_key_rejected")
  }

  @Test("cloud missing key -> skipped lead-in + api_key_missing tag")
  func cloudKeyMissing() async throws {
    let spy = CaptureSpy()
    let runner = makeRunner(spy)
    let step = makeStep(provider: .gemini, model: "gemini-2.0-flash") {
      LLMError.classified(.apiKeyMissing)
    }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(
      result.polishError == "AI cleanup skipped: no Gemini API key set yet. Add one in Settings.")
    #expect(spy.calls.count == 1)
    #expect(spy.calls.first?.tags["polish.error_case"] == "api_key_missing")
    #expect(spy.calls.first?.tags["polish.provider"] == "gemini")
  }

  @Test("cloud out-of-credits -> billing notice + out_of_credits tag (the mislabel fix)")
  func cloudOutOfCredits() async throws {
    let spy = CaptureSpy()
    let runner = makeRunner(spy)
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") {
      LLMError.classified(.outOfCredits)
    }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(
      result.polishError
        == "AI polish failed: your OpenAI account is out of credits. Check your provider billing.")
    #expect(spy.calls.first?.tags["polish.error_case"] == "out_of_credits")
  }

  @Test("Ollama unreachable -> Ollama-specific notice + provider_unreachable tag")
  func ollamaUnreachable() async throws {
    let spy = CaptureSpy()
    let runner = makeRunner(spy)
    let step = makeStep(provider: .ollama, model: "llama3.2") {
      LLMError.classified(.providerUnreachable)
    }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(
      result.polishError == "AI polish failed: Ollama isn't reachable. Start Ollama and try again.")
    #expect(spy.calls.first?.tags["polish.error_case"] == "provider_unreachable")
    #expect(spy.calls.first?.tags["polish.provider"] == "ollama")
    #expect(spy.calls.first?.extra?["model"] as? String == "llama3.2")
  }

  // MARK: - Timeout

  @Test("runner polish-budget timeout -> timed_out tag + is_timeout=true")
  func polishTimeout() async throws {
    let spy = CaptureSpy()
    // Polish step's cloud budget is 5s; throwing below 6s injects a TimeoutError
    // for it (the executor short-circuits before calling the polisher).
    let executor = FakeTimeoutExecutor(throwBelowSeconds: 6.0)
    let runner = TextProcessingRunner(captureError: spy.sink, timeoutExecutor: executor.run)
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") {
      LLMError.requestFailed("unused")
    }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(spy.calls.count == 1)
    #expect(spy.calls.first?.tags["polish.error_case"] == "timed_out")
    #expect(spy.calls.first?.tags["polish.is_timeout"] == "true")
    #expect(result.polishError?.hasPrefix("AI cleanup skipped:") == true)
  }

  // MARK: - Apple Intelligence is excluded

  @Test("Apple Intelligence keeps today's exact wording and fires NO runner capture")
  func appleIntelligenceExcluded() async throws {
    let spy = CaptureSpy()
    let runner = makeRunner(spy)
    let step = makeStep(provider: .appleIntelligence, model: "apple-intelligence") {
      LLMError.requestFailed("boom")
    }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(
      result.polishError == "AI polish failed: "
        + LLMError.requestFailed("boom").localizedDescription)
    #expect(spy.calls.isEmpty)
  }

  // MARK: - No-false-positive boundary

  @Test("a cancelled cloud request fires no capture and surfaces no notice")
  func cancellationLikeIgnored() async throws {
    let spy = CaptureSpy()
    let runner = makeRunner(spy)
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") { URLError(.cancelled) }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(result.polishError == nil)
    #expect(spy.calls.isEmpty)
  }

  @Test("a successful polish fires no capture")
  func successNoCapture() async throws {
    let spy = CaptureSpy()
    let runner = makeRunner(spy)
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"
    step.makePolisher = { _, _, _ in SucceedingPolisher() }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(result.polishError == nil)
    #expect(spy.calls.isEmpty)
  }

  /// Polisher that returns clean text (no throw) for the success-path test.
  private struct SucceedingPolisher: TranscriptPolisher {
    func polish(
      text: String,
      instructions: PolishInstructions,
      config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      LLMResult(polishedText: "So I was thinking we could ship the new thing next week.")
    }
  }
}
