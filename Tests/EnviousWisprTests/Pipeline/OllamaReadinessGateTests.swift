import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #1305: the Ollama readiness preflight gate in `LLMPolishStep.process()` and
/// the runner's SURFACED-SKIP handling of its throw. The gate must fire before
/// any polisher construction (zero connector invocations on a not-ready
/// answer), and the runner must treat `localPolishNotReady` as the third class
/// between Failure and Bypass: user notice YES (pinned skipped-tone copy),
/// Sentry capture NO, `llm.polish_skipped` YES. These sit alongside the
/// silent-set locks in `TextProcessingRunnerTests` and the surfaced-failure
/// locks in `TextProcessingRunnerCaptureTests` so no arm can silently regress.
@MainActor
@Suite("Ollama readiness gate (#1305)")
struct OllamaReadinessGateTests {

  /// Clears the polish step's <=3-word short-circuit so the gate is reached.
  private static let longTranscript =
    "quick email to the ethics committee chair subject revised protocol requesting review"

  /// Polisher that records invocations; the gate contract is that it is never
  /// constructed (factory never called), let alone invoked, on a not-ready probe.
  /// Counts polisher invocations on an actor so the read after `process()`
  /// returns is race-free (`polish` is not main-actor isolated — see
  /// `TranscriptPolisher.polish`).
  private actor InvocationCounter {
    private(set) var count = 0
    func increment() { count += 1 }
  }

  private struct CannedPolisher: TranscriptPolisher {
    let invocationCounter: InvocationCounter

    func polish(
      text: String,
      instructions: PolishInstructions,
      config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      await invocationCounter.increment()
      return LLMResult(polishedText: "Quick email to the ethics committee chair about it.")
    }
  }

  private func makeStep(
    probe: @escaping @MainActor (String) async -> OllamaReadiness,
    invocationCounter: InvocationCounter = InvocationCounter()
  ) -> (step: LLMPolishStep, factoryCalls: () -> Int) {
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .ollama
    step.llmModel = "llama3.2"
    step.ollamaReadinessProbe = probe
    let factoryCounter = Counter()
    step.makePolisher = { _, _, _ in
      factoryCounter.value += 1
      return CannedPolisher(invocationCounter: invocationCounter)
    }
    return (step, { factoryCounter.value })
  }

  @MainActor
  private final class Counter {
    var value = 0
  }

  // MARK: - #1914 facts-binding harness

  /// Captures the `LLMProviderConfig` the step actually built, so a test can
  /// assert what the OUTGOING REQUEST would carry rather than what the step was
  /// told. Actor-isolated because `polish` is not main-actor isolated.
  private actor ConfigCapture {
    private(set) var config: LLMProviderConfig?
    func record(_ c: LLMProviderConfig) { config = c }
  }

  private struct CapturingPolisher: TranscriptPolisher {
    let capture: ConfigCapture
    func polish(
      text: String,
      instructions: PolishInstructions,
      config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      await capture.record(config)
      return LLMResult(polishedText: "Quick email to the ethics committee chair about it.")
    }
  }

  /// Builds a step whose readiness answer carries the given facts, and returns
  /// the capture so the test can read the resolved config.
  ///
  /// `model` defaults to a name that gives NO clue about thinking capability —
  /// it matches neither the retired prefix list nor any real family. If a
  /// name-based fallback ever creeps back in, these tests keep passing only if
  /// the daemon's fact is genuinely what decided the outcome.
  private func makeFactsStep(
    facts: OllamaModelFacts,
    model: String = "some-unknown-model:7b"
  ) -> (step: LLMPolishStep, capture: ConfigCapture) {
    let capture = ConfigCapture()
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .ollama
    step.llmModel = model
    step.ollamaReadinessProbe = { _ in .ready(facts: facts) }
    step.makePolisher = { _, _, _ in CapturingPolisher(capture: capture) }
    return (step, capture)
  }

  private func context(_ text: String = longTranscript) -> TextProcessingContext {
    TextProcessingContext(text: text, language: "en")
  }

  // MARK: - Gate behavior (step level)

  @Test("serverDown throws localPolishNotReady(.providerUnreachable) with ZERO connector work")
  func serverDownThrowsBeforeAnyPolisher() async {
    var probeCalls = 0
    let (step, factoryCalls) = makeStep(probe: { _ in
      probeCalls += 1
      return .serverDown
    })

    await #expect(throws: LLMError.localPolishNotReady(.providerUnreachable)) {
      _ = try await step.process(context())
    }
    #expect(probeCalls == 1)
    // The whole point of the preflight: no polisher, no request, no retry loop.
    #expect(factoryCalls() == 0)
  }

  @Test("modelMissing throws localPolishNotReady(.modelUnavailable) with ZERO connector work")
  func modelMissingThrowsBeforeAnyPolisher() async {
    let (step, factoryCalls) = makeStep(probe: { _ in .modelMissing })

    await #expect(throws: LLMError.localPolishNotReady(.modelUnavailable)) {
      _ = try await step.process(context())
    }
    #expect(factoryCalls() == 0)
  }

  /// #1914: the state the never-auto-arm refusal creates. It must reach the
  /// user as its OWN reason, not folded into `.modelUnavailable`, because the
  /// two carry different sentences and one of them would be false.
  @Test("noModelSelected throws localPolishNotReady(.noModelSelected) with ZERO connector work")
  func noModelSelectedThrowsBeforeAnyPolisher() async {
    let (step, factoryCalls) = makeStep(probe: { _ in .noModelSelected })

    await #expect(throws: LLMError.localPolishNotReady(.noModelSelected)) {
      _ = try await step.process(context())
    }
    #expect(factoryCalls() == 0)
  }

  /// The discriminating control: the two readiness states must not produce the
  /// same error. Without this, mapping both to one reason would still pass the
  /// test above.
  @Test("noModelSelected and modelMissing produce DIFFERENT errors")
  func noModelSelectedIsNotModelMissing() async {
    let (selectedStep, _) = makeStep(probe: { _ in .noModelSelected })
    await #expect(throws: LLMError.localPolishNotReady(.noModelSelected)) {
      _ = try await selectedStep.process(context())
    }

    let (missingStep, _) = makeStep(probe: { _ in .modelMissing })
    // Fails if the gate collapsed the two states onto one reason.
    await #expect(throws: LLMError.localPolishNotReady(.modelUnavailable)) {
      _ = try await missingStep.process(context())
    }
  }

  @Test("ready proceeds to the polisher exactly as before")
  func readyProceedsToPolisher() async throws {
    let invocationCounter = InvocationCounter()
    let (step, factoryCalls) = makeStep(
      probe: { _ in .ready(facts: OllamaModelFacts(isRemote: false, thinks: false)) },
      invocationCounter: invocationCounter)

    let result = try await step.process(context())

    #expect(factoryCalls() == 1)
    #expect(await invocationCounter.count == 1)
    #expect(result.polishedText == "Quick email to the ethics committee chair about it.")
    #expect(result.llmProvider == "ollama")
  }

  @Test("the probe receives the entry-snapshot model")
  func probeReceivesSnapshotModel() async throws {
    var probedModel: String?
    let (step, _) = makeStep(probe: { model in
      probedModel = model
      return .ready(facts: OllamaModelFacts(isRemote: false, thinks: false))
    })
    step.llmModel = "gemma3n:e4b"

    _ = try await step.process(context())

    #expect(probedModel == "gemma3n:e4b")
  }

  @Test("non-Ollama providers never consult the probe")
  func nonOllamaProvidersSkipProbe() async throws {
    var probeCalls = 0
    let (step, _) = makeStep(probe: { _ in
      probeCalls += 1
      return .serverDown
    })
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"

    _ = try? await step.process(context())

    #expect(probeCalls == 0)
  }

  @Test("the too-short bypass short-circuits before the probe runs")
  func tooShortBypassPrecedesProbe() async throws {
    var probeCalls = 0
    let (step, factoryCalls) = makeStep(probe: { _ in
      probeCalls += 1
      return .serverDown
    })

    let result = try await step.process(context("just two words"))

    #expect(probeCalls == 0)
    #expect(factoryCalls() == 0)
    #expect(result.polishedText == nil)
  }

  // MARK: - #1914 completed-only remoteness carrier

  /// A polisher that gets past readiness and then throws. The step returns no
  /// context on this path; the wiring-level test confirms that the runner's
  /// retained pre-step context reaches metrics with remoteness absent.
  private struct ThrowingPolisher: TranscriptPolisher {
    func polish(
      text: String,
      instructions: PolishInstructions,
      config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      throw LLMError.classified(.providerServerError)
    }
  }

  @Test(
    "a completed Ollama polish carries the daemon's remoteness answer, either way",
    arguments: [true, false])
  func completedOllamaPolishCarriesRemoteness(remote: Bool) async throws {
    let (step, _) = makeFactsStep(facts: OllamaModelFacts(isRemote: remote, thinks: false))

    let result = try await step.process(context())

    #expect(result.polishRanRemote == remote)
    #expect(result.polishedText != nil)
  }

  /// The third state, and the reason the carrier is `Bool?`. OpenAI has no
  /// daemon to ask, so `nil` is the honest answer; `false` would claim the model
  /// ran locally in Ollama, which is not what happened.
  @Test("a completed non-Ollama polish carries no remoteness at all")
  func completedCloudPolishCarriesNoRemoteness() async throws {
    let (step, _) = makeStep(
      probe: { _ in .ready(facts: OllamaModelFacts(isRemote: true, thinks: false)) })
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"

    let result = try await step.process(context())

    #expect(result.polishRanRemote == nil)
    #expect(result.polishedText != nil)
  }

  /// Establishes the PRECONDITION for the tabling: a remote-ready attempt that
  /// then fails leaves the step by throwing, so it never reaches the stamp and
  /// returns no context at all. Stated precisely because that is all this proves.
  ///
  /// The stamped value on a failed dictation is asserted where it can actually be
  /// read — `KernelFinalizationWiringTests.failedPolishLeavesRemotenessNil`, which
  /// runs the real wiring and inspects the persisted metrics — and the emitted
  /// payload is asserted in `DictationCompletedRouteFieldsTests`.
  @Test("a remote-ready attempt whose polish throws never reaches the stamp")
  func failedRemotePolishThrowsBeforeTheStamp() async throws {
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .ollama
    step.llmModel = "gpt-oss:20b-cloud"
    step.ollamaReadinessProbe = { _ in
      .ready(facts: OllamaModelFacts(isRemote: true, thinks: false))
    }
    step.makePolisher = { _, _, _ in ThrowingPolisher() }

    await #expect(throws: (any Error).self) {
      _ = try await step.process(self.context())
    }
  }

  /// Every readiness skip, enumerated rather than sampled: these are the three
  /// non-ready cases `OllamaReadiness` has. Each throws, so like the failure
  /// above it returns no context and cannot have stamped anything. Enumerated
  /// because a fourth case added later must decide this deliberately, and a
  /// sampled test would let it default to whatever the new arm happened to do.
  @Test(
    "every readiness skip throws before the stamp, so none can carry remoteness",
    arguments: [
      OllamaReadiness.serverDown,
      OllamaReadiness.modelMissing,
      OllamaReadiness.noModelSelected,
    ])
  func readinessSkipsThrowBeforeTheStamp(readiness: OllamaReadiness) async {
    let (step, _) = makeStep(probe: { _ in readiness })

    await #expect(throws: (any Error).self) {
      _ = try await step.process(self.context())
    }
  }

  /// The bypass path returns the CALLER's context, so a value already sitting on
  /// it would ride through untouched. `bypassedContext` clears the field for the
  /// same reason it clears provider and model.
  @Test("the too-short bypass clears any remoteness already on the context")
  func tooShortBypassClearsRemoteness() async throws {
    let (step, _) = makeStep(
      probe: { _ in .ready(facts: OllamaModelFacts(isRemote: true, thinks: false)) })
    var incoming = context("just two words")
    incoming.polishRanRemote = true

    let result = try await step.process(incoming)

    #expect(result.polishRanRemote == nil)
    #expect(result.polishedText == nil)
  }

  // MARK: - Runner surfaced-skip contract (notice YES, Sentry NO, telemetry YES)

  /// Records every runner Sentry capture (same shape as
  /// `TextProcessingRunnerCaptureTests.CaptureSpy`).
  @MainActor
  private final class CaptureSpy {
    private(set) var count = 0
    func sink(
      _ error: any Error, _ category: SentryBreadcrumb.ErrorCategory,
      _ stage: String, _ extra: [String: Any]?, _ tags: [String: String],
      _ fingerprintDetail: String?
    ) {
      count += 1
    }
  }

  private func runThroughRunner(
    probe: @escaping @MainActor (String) async -> OllamaReadiness,
    spy: CaptureSpy
  ) async throws -> TextProcessingRunResult {
    let (step, _) = makeStep(probe: probe)
    let executor = FakeTimeoutExecutor(throwBelowSeconds: 0.0)
    // The preflight path fires no capture and no failure record; it DOES emit a
    // `llm.polish_skipped`, which the tests below assert on via testEventHook, so
    // that one seam stays live. The failure seam is no-op'd so a future mid-flight
    // test here can never reach the real PostHog client (#1446).
    let runner = TextProcessingRunner(
      telemetry: .init(
        captureError: spy.sink, recordPolishFailed: { _, _, _, _, _ in },
        // This suite asserts on the real `llm.polish_skipped` via testEventHook.
        recordPolishSkipped: TextProcessingRunner.TelemetrySeams.live.recordPolishSkipped),
      timeoutExecutor: executor.run)
    return try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])
  }

  @Test("server down -> pinned skipped-tone notice, raw text, NO Sentry capture")
  func serverDownSurfacedSkip() async throws {
    let spy = CaptureSpy()

    let result = try await runThroughRunner(probe: { _ in .serverDown }, spy: spy)

    #expect(
      result.polishError
        == "AI cleanup skipped: Ollama isn't running. Start it in Settings → AI Polish.")
    // The completion planner must read this as a skip, not a hard failure —
    // the "Polish failed" overlay is keyed off this exact predicate.
    #expect(PolishFailureReason.isSkipNotice(result.polishError ?? "") == true)
    #expect(result.context.polishedText == nil)
    #expect(result.context.llmProvider == nil)
    #expect(result.context.text == Self.longTranscript)
    // Adversarial lock: an expected not-ready state fires NO Sentry error.
    #expect(spy.count == 0)
  }

  @Test("model missing -> pinned skipped-tone notice, raw text, NO Sentry capture")
  func modelMissingSurfacedSkip() async throws {
    let spy = CaptureSpy()

    let result = try await runThroughRunner(probe: { _ in .modelMissing }, spy: spy)

    #expect(
      result.polishError
        == "AI cleanup skipped: the selected Ollama model isn't installed. "
        + "Download it or pick another in Settings → AI Polish."
    )
    #expect(PolishFailureReason.isSkipNotice(result.polishError ?? "") == true)
    #expect(result.context.polishedText == nil)
    #expect(spy.count == 0)
  }

  /// #1914 END TO END, and this is the test that stands for the founder's
  /// decision: "a pill flash saying no polish model selected while still
  /// pasting the raw output". Every clause of that sentence is an assertion
  /// here — the exact pill, the skip tone, and the deterministic text arriving
  /// intact rather than the run failing.
  @Test("no model selected -> pinned skipped-tone notice, raw text, NO Sentry capture")
  func noModelSelectedSurfacedSkip() async throws {
    let spy = CaptureSpy()

    let result = try await runThroughRunner(probe: { _ in .noModelSelected }, spy: spy)

    #expect(
      result.polishError
        == "AI cleanup skipped: no polish model selected. Pick one in Settings → AI Polish.")
    // Skip tone, not failure tone: the completion planner keys the "Polish
    // failed. Using raw text." overlay off this exact predicate, and declining
    // to choose a model for the user is not a breakage to apologise for.
    #expect(PolishFailureReason.isSkipNotice(result.polishError ?? "") == true)
    // "while still pasting the raw output" — the heart is untouched. The
    // deterministic text is what reaches the user, unpolished and complete.
    #expect(result.context.text == Self.longTranscript)
    #expect(result.context.polishedText == nil)
    #expect(result.context.llmProvider == nil)
    // Not our defect, so nothing pages us.
    #expect(spy.count == 0)
  }

  // testEventHook is DEBUG-only (CI also compiles tests in release); the skip
  // telemetry assertions are DEBUG-gated like DualModePolishTelemetryTests.
  #if DEBUG
    @Test("server down emits llm.polish_skipped with local_polish_ollama_server_down")
    func serverDownEmitsSkipTelemetry() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      let spy = CaptureSpy()

      _ = try await runThroughRunner(probe: { _ in .serverDown }, spy: spy)

      let event = try await waiter.waitForEvent(named: "llm.polish_skipped")
      #expect(event.stringProps["provider"] == "ollama")
      #expect(event.stringProps["skip_reason"] == "local_polish_ollama_server_down")
    }

    @Test("model missing emits llm.polish_skipped with local_polish_ollama_model_missing")
    func modelMissingEmitsSkipTelemetry() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      let spy = CaptureSpy()

      _ = try await runThroughRunner(probe: { _ in .modelMissing }, spy: spy)

      let event = try await waiter.waitForEvent(named: "llm.polish_skipped")
      #expect(event.stringProps["provider"] == "ollama")
      #expect(event.stringProps["skip_reason"] == "local_polish_ollama_model_missing")
    }

    /// #1914: the outcome must be COUNTABLE, not only visible. Without the
    /// `PolishSkipReason` mapping the pill still shows and this event silently
    /// never fires, so how often we decline to arm a model for someone would be
    /// unanswerable while looking, from the user's side, completely normal.
    @Test("no model selected emits llm.polish_skipped with local_polish_ollama_no_model_selected")
    func noModelSelectedEmitsSkipTelemetry() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      let spy = CaptureSpy()

      _ = try await runThroughRunner(probe: { _ in .noModelSelected }, spy: spy)

      let event = try await waiter.waitForEvent(named: "llm.polish_skipped")
      #expect(event.stringProps["provider"] == "ollama")
      #expect(event.stringProps["skip_reason"] == "local_polish_ollama_no_model_selected")
    }
  #endif

  // MARK: - #1914 the readiness payload must reach the outgoing request

  /// THE test this chunk exists for. Swift lets `case .ready:` match and discard
  /// the associated value, so nothing in the compiler notices if the binding is
  /// dropped and every model silently falls back to the tight budget — which is
  /// the original #1914 defect. This asserts the facts reach the CONFIG the
  /// connector would send, not merely that the step was handed them.
  ///
  /// Mutation-verified: neutralising the bound `facts.thinks` in production
  /// fails this test specifically.
  @Test("thinking facts reach the outgoing config: large floor AND think low")
  func thinkingFactsReachTheConfig() async throws {
    let (step, capture) = makeFactsStep(
      facts: OllamaModelFacts(isRemote: false, thinks: true))

    _ = try await step.process(context())

    let config = await capture.config
    #expect(config?.outputTokens == .capped(LLMConstants.ollamaThinkingMaxTokens))
    #expect(config?.thinking == .level("low"))
  }

  /// The negative half. Without it, an implementation that hard-coded thinking
  /// on would pass the test above while quietly enlarging every request.
  @Test("non-thinking facts reach the outgoing config: tight floor AND no think field")
  func nonThinkingFactsReachTheConfig() async throws {
    let (step, capture) = makeFactsStep(
      facts: OllamaModelFacts(isRemote: false, thinks: false))

    _ = try await step.process(context())

    let config = await capture.config
    #expect(config?.outputTokens == .capped(LLMConstants.ollamaMaxTokens))
    #expect(config?.thinking == nil)
  }

  /// Independence control. `isRemote` must influence neither the budget nor the
  /// thinking level — where a model runs does not tell you whether it reasons.
  /// A remote non-thinking model and a local thinking model are both real, so
  /// deriving one fact from the other would break both.
  @Test("isRemote changes neither the token floor nor the thinking level")
  func remotenessDoesNotDetermineBudgetOrThinking() async throws {
    // Remote + non-thinking → tight floor, no think. Same as local non-thinking.
    let (remotePlain, remotePlainCapture) = makeFactsStep(
      facts: OllamaModelFacts(isRemote: true, thinks: false))
    _ = try await remotePlain.process(context())
    let plain = await remotePlainCapture.config
    #expect(plain?.outputTokens == .capped(LLMConstants.ollamaMaxTokens))
    #expect(plain?.thinking == nil)

    // Remote + thinking → large floor and low. Same as local thinking.
    let (remoteThinks, remoteThinksCapture) = makeFactsStep(
      facts: OllamaModelFacts(isRemote: true, thinks: true))
    _ = try await remoteThinks.process(context())
    let thinks = await remoteThinksCapture.config
    #expect(thinks?.outputTokens == .capped(LLMConstants.ollamaThinkingMaxTokens))
    #expect(thinks?.thinking == .level("low"))
  }

  /// A name that WOULD have matched the retired prefix list must not get the
  /// thinking budget when the daemon says it does not think. This is the direct
  /// freeze against a name-based fallback creeping back in beside the capability.
  @Test("a formerly-listed family name does not override the reported capability")
  func retiredFamilyNameDoesNotOverrideCapability() async throws {
    let (step, capture) = makeFactsStep(
      facts: OllamaModelFacts(isRemote: false, thinks: false), model: "gemma4:latest")

    _ = try await step.process(context())

    let config = await capture.config
    #expect(config?.outputTokens == .capped(LLMConstants.ollamaMaxTokens))
    #expect(config?.thinking == nil)
  }
}
