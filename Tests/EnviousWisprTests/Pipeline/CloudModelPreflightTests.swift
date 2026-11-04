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
    step.makePolisher = { _, _, _, _ in
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
        from: LLMError.classified(.modelUnavailable), provider: .gemini, model: "gemini-x")
        == .cloudModelUnavailable)
    #expect(
      TextProcessingRunner.setupEvidence(
        from: LLMError.classified(.modelUnavailable), provider: .ollama, model: "llama3.2") == nil)
    #expect(
      TextProcessingRunner.setupEvidence(
        from: LLMError.classified(.accessDenied), provider: .openAI, model: "gpt-x") == nil)
    // #4353 G5: a leftover audio-input model's 400 is the same problem; an ordinary 400 is not.
    #expect(
      TextProcessingRunner.setupEvidence(
        from: LLMError.classified(.badRequest), provider: .gemini, model: "gemini-3.5-transcribe")
        == .cloudModelUnavailable)
    #expect(
      TextProcessingRunner.setupEvidence(
        from: LLMError.classified(.badRequest), provider: .gemini, model: "gemini-3.7-flash") == nil)
  }

  /// #4353 G5: the one shared reading, over every failure reason and provider.
  @Test("only a gone model or a leftover audio model's 400 means the cloud model cannot be used")
  func sharedReading() {
    for reason in PolishFailureReason.allCases {
      for provider in LLMProvider.allCases {
        let cloud = [LLMProvider.openAI, .gemini, .claude].contains(provider)
        let ordinary = reason.meansCloudModelUnavailable(provider: provider, model: "some-model")
        let audio = reason.meansCloudModelUnavailable(
          provider: provider, model: "gpt-4o-audio-preview")
        #expect(ordinary == (cloud && reason == .modelUnavailable), "\(reason) \(provider)")
        #expect(
          audio == (cloud && (reason == .modelUnavailable || reason == .badRequest)),
          "\(reason) \(provider) audio")
        #expect(reason.meansCloudModelUnavailable(provider: provider, model: " ") == false)
      }
    }
  }

  @Test("an empty selection is never retried")
  func notRetryable() {
    #expect(LLMRetryPolicy.isRetryable(LLMError.cloudModelNotSelected(.openAI)) == false)
  }

  private struct GonePolisher: TranscriptPolisher {
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      throw LLMError.classified(.modelUnavailable)
    }
  }

  private struct BadRequestPolisher: TranscriptPolisher {
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      throw LLMError.classified(.badRequest)
    }
  }

  @Test("#4353 G5 a leftover audio model's 400 gets the named notice; an ordinary 400 does not")
  func audioModelRejectionIsNamed() async throws {
    let spies = Spies()
    let audio = makeStep(.gemini, model: "gemini-3.5-transcribe", spies)
    audio.makePolisher = { _, _, _, _ in BadRequestPolisher() }
    let take = PolishSetupTakeContext(
      provider: .gemini, model: "gemini-3.5-transcribe", configurationRevision: 1, episode: nil)
    let result = try await run(audio, spies, take: take)
    #expect(result.polishNotice?.text == "gemini-3.5-transcribe no longer works. Select a new cloud model.")
    #expect(result.polishTakeOutcome?.evidence == .cloudModelUnavailable)
    #expect(result.cloudSetupOutcome == .modelUnavailable(provider: .gemini, model: "gemini-3.5-transcribe"))
    #expect(result.context.text == Self.longTranscript)

    let ordinary = makeStep(.gemini, model: "gemini-3.7-flash", spies)
    ordinary.makePolisher = { _, _, _, _ in BadRequestPolisher() }
    let plain = try await run(ordinary, spies)
    #expect(plain.polishNotice?.text != "gemini-3.7-flash no longer works. Select a new cloud model.")
    #expect(plain.cloudSetupOutcome == nil)
    #expect(plain.context.text == Self.longTranscript)
  }

  @Test("a cloud model the provider says is gone is named in the notice, from the take's model")
  func goneModelIsNamed() async throws {
    let spies = Spies()
    let step = makeStep(.openAI, model: "gpt-x", spies)
    step.makePolisher = { _, _, _, _ in GonePolisher() }
    let result = try await run(step, spies)
    #expect(result.polishNotice?.leadIn == .failed)
    #expect(result.polishNotice?.text == "gpt-x no longer works. Select a new cloud model.")
    #expect(result.context.text == Self.longTranscript)

    // Ollama's own missing model keeps its own sentence.
    let local = makeStep(.ollama, model: "llama3.2", spies)
    local.ollamaReadinessProbe = { _ in .ready(facts: OllamaModelFacts(isRemote: false, thinks: false)) }
    local.makePolisher = { _, _, _, _ in GonePolisher() }
    let ollama = try await run(local, spies)
    #expect(ollama.polishNotice?.text != "llama3.2 no longer works. Select a new cloud model.")
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
