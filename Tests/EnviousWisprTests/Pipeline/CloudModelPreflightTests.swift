import EnviousWisprCore
@testable import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #4353 D3: a cloud provider (OpenAI, Gemini, Claude) with no model chosen. The polish step
/// stops before any key read, connector or request; the dictation pastes its cleaned text with
/// the skipped notice; one `llm.polish_skipped`, no failure count, no Sentry capture.
@MainActor
@Suite("Cloud polish with no model chosen (#4353)", .tags(.productOutcome))
struct CloudModelPreflightTests {

  private static let longTranscript =
    "quick email to the ethics committee chair subject revised protocol requesting review"

  @MainActor
  final class Spies {
    var factoryCalls = 0
    var captures = 0
    var failures: [String] = []
    var skips: [(provider: String, reason: String, takeID: String?)] = []
    var classified: [PolishSetupEvidence] = []
  }

  private struct CannedPolisher: TranscriptPolisher {
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      LLMResult(polishedText: "Quick email to the ethics committee chair about it.")
    }
  }

  private func makeStep(_ provider: LLMProvider, model: String, _ spies: Spies) -> LLMPolishStep {
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = provider
    step.llmModel = model
    step.makePolisher = { _, _, _ in
      spies.factoryCalls += 1
      return CannedPolisher()
    }
    step.ollamaReadinessProbe = { _ in .noModelSelected }
    return step
  }

  private func run(
    _ step: LLMPolishStep, _ spies: Spies, text: String = longTranscript,
    take: PolishSetupTakeContext? = nil
  ) async throws -> TextProcessingRunResult {
    let runner = TextProcessingRunner(
      telemetry: .init(
        captureError: { _, _, _, _, _, _ in spies.captures += 1 },
        recordPolishFailed: { _, _, reason, _, _ in spies.failures.append(reason) },
        recordPolishSkipped: { spies.skips.append(($0, $1, $2)) }),
      timeoutExecutor: FakeTimeoutExecutor(throwBelowSeconds: 0.0).run)
    guard let take else {
      return try await runner.run(
        rawText: text, evidence: .locked("en"), targetAppName: nil, steps: [step],
        takeID: "take-A")
    }
    let probe = PolishSetupTakeProbe(
      takeID: "take-A", context: take,
      classify: {
        spies.classified.append($0)
        return nil
      },
      recordTerminalProblem: { _, _ in }, now: { .now })
    return try await runner.run(
      rawText: text, evidence: .locked("en"), targetAppName: nil, steps: [step],
      polishSetup: probe, takeID: "take-A")
  }

  @Test(
    "no model chosen: cleaned text, skipped notice, one skip, no request",
    arguments: [LLMProvider.openAI, .gemini, .claude])
  func emptyCloudModelIsASurfacedSkip(provider: LLMProvider) async throws {
    let spies = Spies()
    let result = try await run(makeStep(provider, model: "", spies), spies)

    #expect(spies.factoryCalls == 0, "no connector may be built, so no key is read")
    #expect(result.context.text == Self.longTranscript)
    #expect(result.context.polishedText == nil)
    #expect(result.context.llmProvider == nil)
    #expect(result.context.llmModel == nil)
    #expect(result.context.polishMetadata == nil)
    #expect(result.context.polishWasBypassed)
    #expect(result.polishNotice?.leadIn == .skipped)
    #expect(result.polishNotice == PolishFailureReason.noModelSelected.notice(provider: provider))
    #expect(spies.skips.count == 1)
    #expect(spies.skips.first?.provider == provider.rawValue)
    #expect(spies.skips.first?.reason == "cloud_no_model_selected")
    #expect(spies.skips.first?.takeID == "take-A")
    #expect(spies.failures.isEmpty)
    #expect(spies.captures == 0)
  }

  @Test("the take's outcome says no model was chosen, with no request time")
  func outcomeCarriesEvidence() async throws {
    let spies = Spies()
    let take = PolishSetupTakeContext(
      provider: .claude, model: "", configurationRevision: 4, episode: nil)
    let started = ContinuousClock.now
    let result = try await run(makeStep(.claude, model: "", spies), spies, take: take)
    let outcome = try #require(result.polishTakeOutcome)
    #expect(outcome.result == .skippedWithNotice)
    #expect(outcome.evidence == .cloudNoModel)
    #expect(outcome.context == take)
    #expect(outcome.keyReadAt == nil)
    #expect(outcome.observedAt >= started)
    #expect(spies.classified == [.cloudNoModel])
  }

  @Test("a model the cloud provider says does not exist is typed as a cloud model problem")
  func requestTimeUnavailability() {
    #expect(
      TextProcessingRunner.setupEvidence(
        from: LLMError.classified(.modelUnavailable), provider: .gemini) == .cloudModelUnavailable)
    #expect(
      TextProcessingRunner.setupEvidence(
        from: LLMError.classified(.modelUnavailable), provider: .ollama) == nil)
    #expect(
      TextProcessingRunner.setupEvidence(
        from: LLMError.classified(.accessDenied), provider: .openAI) == nil)
  }

  @Test("an empty selection is never retried")
  func notRetryable() {
    #expect(LLMRetryPolicy.isRetryable(LLMError.cloudModelNotSelected(.openAI)) == false)
  }

  // MARK: - Controls

  @Test("a chosen cloud model still polishes")
  func chosenModelPolishes() async throws {
    let spies = Spies()
    let result = try await run(makeStep(.openAI, model: "gpt-6-luna", spies), spies)
    #expect(spies.factoryCalls == 1)
    #expect(result.context.polishedText != nil)
    #expect(spies.skips.isEmpty)
  }

  @Test("a too-short dictation stays a quiet bypass, before the model check")
  func shortTextBypassComesFirst() async throws {
    let spies = Spies()
    let result = try await run(makeStep(.openAI, model: "", spies), spies, text: "thanks")
    #expect(spies.factoryCalls == 0)
    #expect(result.polishNotice == nil)
    #expect(spies.skips.allSatisfy { $0.reason != "cloud_no_model_selected" })
  }

  @Test("Ollama with no model keeps its own check")
  func ollamaKeepsItsGate() async throws {
    let spies = Spies()
    _ = try await run(makeStep(.ollama, model: "", spies), spies)
    #expect(spies.skips.map(\.reason) == ["local_polish_ollama_no_model_selected"])
  }
}
