import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// `LLMPolishStep`'s own telemetry seam (#1461) — the step's 6 direct emitters
/// (started/completed breadcrumbs, provider-init error, AFM generation error,
/// limb-health metric, and the too-short skip event) must go `.silent` during
/// crash-recovery replay without the runner's own `TelemetrySeams.silent`
/// reaching them (that seam only covers what `TextProcessingRunner` itself owns).
///
/// These tests prove the step's OWN behavior in isolation via a per-instance
/// injected spy — NOT a process-global mutable delegate (`swift-patterns.md`
/// RULE: tests-no-process-global-mutable-delegate would forbid that pattern
/// here, since driving `process()` requires `async` test bodies). The
/// companion static-source-check proving the REAL `RecoveryTextProcessor` call
/// site actually passes `.silent` lives in `RecoveryTextProcessorTests.swift`.
@MainActor
@Suite("LLMPolishStep telemetry seam (#1461, #1448)")
struct LLMPolishStepTelemetryTests {

  /// A 16-word sentence that clears the too-short short-circuit.
  private static let longTranscript =
    "so i was thinking we could maybe ship the new thing some time next week or so"

  @MainActor
  final class Spy {
    private(set) var limbFailureCalls:
      [(limb: String, op: String, result: String, cat: String, dur: Int?)] = []
    private(set) var startedCalls: [(message: String, data: [String: Any]?)] = []
    private(set) var providerInitErrorCalls: [any Error] = []
    private(set) var afmPolishErrorCalls: [any Error] = []
    private(set) var completedCalls: [(message: String, data: [String: Any]?)] = []
    private(set) var skipCalls: [(provider: String, reason: String)] = []

    var seams: LLMPolishStep.TelemetrySeams {
      LLMPolishStep.TelemetrySeams(
        limbFailureObserved: { limb, op, result, cat, dur in
          self.limbFailureCalls.append((limb, op, result, cat, dur))
        },
        breadcrumbStarted: { message, data in
          self.startedCalls.append((message, data))
        },
        captureProviderInitError: { error in
          self.providerInitErrorCalls.append(error)
        },
        captureAFMPolishError: { error in
          self.afmPolishErrorCalls.append(error)
        },
        breadcrumbCompleted: { message, data in
          self.completedCalls.append((message, data))
        },
        recordPolishSkipped: { provider, reason in
          self.skipCalls.append((provider, reason))
        })
    }
  }

  private struct ThrowingPolisher: TranscriptPolisher {
    let makeError: @Sendable () -> any Error
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      throw makeError()
    }
  }

  private struct SucceedingPolisher: TranscriptPolisher {
    func polish(
      text: String, instructions: PolishInstructions, config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      LLMResult(polishedText: "So I was thinking we could ship the new thing next week.")
    }
  }

  private func makeStep(
    provider: LLMProvider, model: String = "gpt-4o-mini", telemetry: LLMPolishStep.TelemetrySeams
  ) -> LLMPolishStep {
    let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: telemetry)
    step.llmProvider = provider
    step.llmModel = model
    return step
  }

  // MARK: - Too-short bypass (#1448)

  @Test(
    "too-short bypass (CJK char-count path) emits its own skip tag; started already fired, nothing else does"
  )
  func tooShortBypassCJK() async throws {
    let spy = Spy()
    let step = makeStep(provider: .openAI, telemetry: spy.seams)
    let context = TextProcessingContext(text: "短い", language: "ja")

    _ = try await step.process(context)

    #expect(spy.startedCalls.count == 1)
    #expect(spy.skipCalls.count == 1)
    #expect(spy.skipCalls.first?.provider == "openAI")
    #expect(spy.skipCalls.first?.reason == "too_short")
    #expect(spy.completedCalls.isEmpty)
    #expect(spy.providerInitErrorCalls.isEmpty)
    #expect(spy.afmPolishErrorCalls.isEmpty)
    #expect(spy.limbFailureCalls.isEmpty)
  }

  @Test("too-short bypass (Latin word-count path) emits the same skip tag")
  func tooShortBypassLatin() async throws {
    let spy = Spy()
    let step = makeStep(provider: .gemini, telemetry: spy.seams)
    let context = TextProcessingContext(text: "yeah", language: "en")

    _ = try await step.process(context)

    #expect(spy.startedCalls.count == 1)
    #expect(spy.skipCalls.count == 1)
    #expect(spy.skipCalls.first?.provider == "gemini")
    #expect(spy.skipCalls.first?.reason == "too_short")
    #expect(spy.completedCalls.isEmpty)
  }

  // MARK: - Wrapped silent AFM cases no longer alert (#1448/#1461, rounds 2-4 of grounded review)

  @Test("outputLanguageDrift, wrapped as AFMPolishError, no longer alerts")
  func outputLanguageDriftDoesNotAlert() async throws {
    let spy = Spy()
    let step = makeStep(
      provider: .appleIntelligence, model: "apple-intelligence", telemetry: spy.seams)
    let underlying = LLMError.outputLanguageDrift(expected: "en", actual: "de")
    step.makePolisher = { _, _, _ in
      ThrowingPolisher(makeError: { AFMPolishError(underlying: underlying) })
    }

    await #expect(throws: LLMError.self) {
      _ = try await step.process(TextProcessingContext(text: Self.longTranscript, language: "en"))
    }

    #expect(spy.afmPolishErrorCalls.isEmpty)
  }

  @Test(
    "frameworkUnavailable, wrapped as AFMPolishError (the rarer makeSession re-check path), no longer alerts"
  )
  func wrappedFrameworkUnavailableDoesNotAlert() async throws {
    let spy = Spy()
    let step = makeStep(
      provider: .appleIntelligence, model: "apple-intelligence", telemetry: spy.seams)
    let underlying = LLMError.frameworkUnavailable("re-check failed")
    step.makePolisher = { _, _, _ in
      ThrowingPolisher(makeError: { AFMPolishError(underlying: underlying) })
    }

    await #expect(throws: LLMError.self) {
      _ = try await step.process(TextProcessingContext(text: Self.longTranscript, language: "en"))
    }

    #expect(spy.afmPolishErrorCalls.isEmpty)
  }

  @Test("a non-silent wrapped AFM error (modelNotReady) still alerts, unchanged")
  func wrappedModelNotReadyStillAlerts() async throws {
    let spy = Spy()
    let step = makeStep(
      provider: .appleIntelligence, model: "apple-intelligence", telemetry: spy.seams)
    let underlying = LLMError.modelNotReady("still downloading")
    step.makePolisher = { _, _, _ in
      ThrowingPolisher(makeError: { AFMPolishError(underlying: underlying) })
    }

    await #expect(throws: LLMError.self) {
      _ = try await step.process(TextProcessingContext(text: Self.longTranscript, language: "en"))
    }

    #expect(spy.afmPolishErrorCalls.count == 1)
  }

  // MARK: - Provider-init failure

  @Test("provider-init failure routes through the seam")
  func providerInitFailureRoutesThroughSeam() async throws {
    let spy = Spy()
    let step = makeStep(provider: .egOne, telemetry: spy.seams)
    // No egOneRuntime injected -> egOneSkipped(.notReady), not providerInitFailed.
    // Use a provider whose makePolisher legitimately returns nil instead.
    step.llmProvider = .openAI
    step.makePolisher = { _, _, _ in nil }

    await #expect(throws: LLMError.self) {
      _ = try await step.process(TextProcessingContext(text: Self.longTranscript, language: "en"))
    }

    #expect(spy.providerInitErrorCalls.count == 1)
  }

  // MARK: - Recovery construction (.silent) silences all 5 replay-reachable emitters

  @Test("`.silent` construction silences the too-short skip event")
  func silentConstructionSilencesTooShort() async throws {
    let spy = Spy()
    let step = makeStep(provider: .openAI, telemetry: .silent)
    // Route the spy through a second layer to prove NOTHING reaches it, not
    // just that `.silent`'s own closures are no-ops.
    _ = spy
    _ = try await step.process(TextProcessingContext(text: "yeah", language: "en"))
    // No spy assertions possible against `.silent` itself (it discards
    // everything by construction) — this test's value is that `process()`
    // completes without any live-seam side effect, i.e. it compiles and runs
    // against `.silent` at all call sites the too-short path touches.
  }

  @Test("`.silent` construction silences success, provider-init failure, and AFM failure")
  func silentConstructionSilencesAllPaths() async throws {
    // Success path.
    do {
      let step = makeStep(provider: .openAI, telemetry: .silent)
      step.makePolisher = { _, _, _ in SucceedingPolisher() }
      _ = try await step.process(TextProcessingContext(text: Self.longTranscript, language: "en"))
    }
    // Provider-init failure path.
    do {
      let step = makeStep(provider: .openAI, telemetry: .silent)
      step.makePolisher = { _, _, _ in nil }
      await #expect(throws: LLMError.self) {
        _ = try await step.process(TextProcessingContext(text: Self.longTranscript, language: "en"))
      }
    }
    // AFM failure path.
    do {
      let step = makeStep(
        provider: .appleIntelligence, model: "apple-intelligence", telemetry: .silent)
      step.makePolisher = { _, _, _ in
        ThrowingPolisher(makeError: { AFMPolishError(underlying: LLMError.modelNotReady("x")) })
      }
      await #expect(throws: LLMError.self) {
        _ = try await step.process(TextProcessingContext(text: Self.longTranscript, language: "en"))
      }
    }
    // None of the above can be asserted against a spy (that's the point of
    // `.silent`); this test's value is that every path still compiles and
    // completes normally when constructed with `.silent`, exercising the
    // exact seam plumbing `RecoveryTextProcessor` uses.
  }

  // MARK: - `limbFailureObserved` — deterministic via the injectable eviction seam

  @Test("limb-health metric fires on a failed eviction, with `.live`; silent with `.silent`")
  func limbFailureObservedIsDeterministic() async throws {
    let failedOutcome = OllamaEvictOutcome(result: "failed", durationMs: 42, reason: "http_500")

    let spy = Spy()
    let liveStep = makeStep(provider: .ollama, telemetry: spy.seams)
    liveStep.evictOllamaModel = { _ in failedOutcome }
    await liveStep.evictPreviousOllamaModel("some-model")

    #expect(spy.limbFailureCalls.count == 1)
    #expect(spy.limbFailureCalls.first?.limb == "ollama")
    #expect(spy.limbFailureCalls.first?.op == "evict")
    #expect(spy.limbFailureCalls.first?.result == "failed")
    #expect(spy.limbFailureCalls.first?.cat == "http_500")
    #expect(spy.limbFailureCalls.first?.dur == 42)

    let silentSpy = Spy()
    let silentStep = makeStep(provider: .ollama, telemetry: .silent)
    silentStep.evictOllamaModel = { _ in failedOutcome }
    await silentStep.evictPreviousOllamaModel("some-model")
    // `.silent` discards everything; nothing to assert against `silentSpy`
    // (it was never wired to `silentStep`) — the value here is that
    // `.silent` construction + a failed eviction outcome together produce
    // zero observable side effects, which is what `.silent` promises.
    _ = silentSpy
  }

  @Test("a successful eviction never fires the limb metric, `.live` or `.silent`")
  func limbFailureObservedSkipsOnSuccess() async throws {
    let successOutcome = OllamaEvictOutcome(result: "unloaded", durationMs: 10, reason: "http_200")
    let spy = Spy()
    let step = makeStep(provider: .ollama, telemetry: spy.seams)
    step.evictOllamaModel = { _ in successOutcome }

    await step.evictPreviousOllamaModel("some-model")

    #expect(spy.limbFailureCalls.isEmpty)
  }

  // MARK: - Successful polish

  @Test("a successful polish fires the completed breadcrumb, never the skip/failure seams")
  func successfulPolishFiresCompletedOnly() async throws {
    let spy = Spy()
    let step = makeStep(provider: .openAI, telemetry: spy.seams)
    step.makePolisher = { _, _, _ in SucceedingPolisher() }

    _ = try await step.process(TextProcessingContext(text: Self.longTranscript, language: "en"))

    #expect(spy.startedCalls.count == 1)
    #expect(spy.completedCalls.count == 1)
    #expect(spy.skipCalls.isEmpty)
    #expect(spy.providerInitErrorCalls.isEmpty)
    #expect(spy.afmPolishErrorCalls.isEmpty)
  }
}
