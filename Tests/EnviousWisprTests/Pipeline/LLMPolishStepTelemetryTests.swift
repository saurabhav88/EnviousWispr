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
///
/// `.serialized` (#1593 cloud review): `silentNeverLeaksToRealGlobals` installs
/// the process-wide `TelemetryService.testEventHook` /
/// `SentryBreadcrumb.breadcrumbDelegate` / `captureErrorDelegate` — even though
/// it does so with no `await` in between (immune to intra-suite interleaving
/// per the rule above), `.serialized` also rules out any residual overlap with
/// this suite's OTHER tests, matching `EngineCoordinatorTests.swift`'s
/// precedent for the same globals.
@MainActor
@Suite("LLMPolishStep telemetry seam (#1461, #1448)", .serialized)
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
    // #1593: wrap a spy-backed seam in `.silent(wrapping:)` instead of the
    // bare `.silent` constant, so a regression that makes `.silent` forward
    // to its wrapped seam (or a future refactor that breaks the discard)
    // turns this test red instead of leaving it unfalsifiable.
    let spy = Spy()
    let step = makeStep(provider: .openAI, telemetry: .silent(wrapping: spy.seams))
    _ = try await step.process(TextProcessingContext(text: "yeah", language: "en"))
    #expect(spy.skipCalls.isEmpty)
    #expect(spy.startedCalls.isEmpty)
    #expect(spy.completedCalls.isEmpty)
    #expect(spy.providerInitErrorCalls.isEmpty)
    #expect(spy.afmPolishErrorCalls.isEmpty)
    #expect(spy.limbFailureCalls.isEmpty)
  }

  @Test("`.silent` construction silences success, provider-init failure, and AFM failure")
  func silentConstructionSilencesAllPaths() async throws {
    // Success path.
    let successSpy = Spy()
    do {
      let step = makeStep(provider: .openAI, telemetry: .silent(wrapping: successSpy.seams))
      step.makePolisher = { _, _, _ in SucceedingPolisher() }
      _ = try await step.process(TextProcessingContext(text: Self.longTranscript, language: "en"))
    }
    #expect(successSpy.startedCalls.isEmpty)
    #expect(successSpy.completedCalls.isEmpty)

    // Provider-init failure path.
    let providerInitSpy = Spy()
    do {
      let step = makeStep(provider: .openAI, telemetry: .silent(wrapping: providerInitSpy.seams))
      step.makePolisher = { _, _, _ in nil }
      await #expect(throws: LLMError.self) {
        _ = try await step.process(TextProcessingContext(text: Self.longTranscript, language: "en"))
      }
    }
    #expect(providerInitSpy.providerInitErrorCalls.isEmpty)

    // AFM failure path.
    let afmSpy = Spy()
    do {
      let step = makeStep(
        provider: .appleIntelligence, model: "apple-intelligence",
        telemetry: .silent(wrapping: afmSpy.seams))
      step.makePolisher = { _, _, _ in
        ThrowingPolisher(makeError: { AFMPolishError(underlying: LLMError.modelNotReady("x")) })
      }
      await #expect(throws: LLMError.self) {
        _ = try await step.process(TextProcessingContext(text: Self.longTranscript, language: "en"))
      }
    }
    #expect(afmSpy.afmPolishErrorCalls.isEmpty)
  }

  /// Codex round-1 review of #1593: a spy-only test can't distinguish "correctly
  /// discards" from "ignores its `wrapping:` argument and returns `.live`
  /// unconditionally" — both leave an unrelated injected spy empty, but the
  /// second one leaks every real telemetry call during crash-recovery replay
  /// (the exact #1446 incident class this seam exists to prevent). Closes that
  /// gap by calling `.silent(wrapping: .live)`'s closures directly and proving
  /// they never reach the REAL global sinks `.live` forwards to, with a
  /// positive control proving those same hooks DO fire for `.live` itself (so
  /// a broken hook installation can't silently pass this test too).
  ///
  /// Installs the process-global test delegates synchronously, calls the
  /// closures directly (no `await` in between), and restores them before
  /// returning — the documented-safe shape per `swift-patterns.md`
  /// RULE: tests-no-process-global-mutable-delegate.
  // `TelemetryService.testEventHook` is `#if DEBUG`-only (TelemetryService.swift);
  // an ungated reference here compiles fine in this Debug-config file but fails
  // the required Release test-target build (Codex round-2 review, P1) — mirrors
  // EngineCoordinatorTests.swift's existing `#if DEBUG` gate on its own
  // testEventHook-using tests.
  #if DEBUG
    @Test("`.silent(wrapping: .live)` never reaches the real Sentry/Telemetry globals `.live` uses")
    func silentNeverLeaksToRealGlobals() {
      // The delegate hooks below are `@Sendable`, so the recorder needs
      // reference semantics rather than captured `var`s. Everything in this
      // test runs synchronously on one thread (install -> call closures
      // directly -> read -> restore, no `await` anywhere), so `@unchecked
      // Sendable` on this test-local box is a safe, narrow use, not a
      // production concurrency claim.
      final class Recorder: @unchecked Sendable {
        var telemetryEvents: [String] = []
        var breadcrumbMessages: [String] = []
        var captureErrorCount = 0
      }
      let recorder = Recorder()

      TelemetryService.shared.testEventHook = { recorder.telemetryEvents.append($0.name) }
      defer { TelemetryService.shared.testEventHook = nil }

      SentryBreadcrumb.breadcrumbDelegate = { _, message, _, _ in
        recorder.breadcrumbMessages.append(message)
      }
      defer { SentryBreadcrumb.breadcrumbDelegate = nil }

      SentryBreadcrumb.captureErrorDelegate = { _, _, _, _ in recorder.captureErrorCount += 1 }
      defer { SentryBreadcrumb.captureErrorDelegate = nil }

      // Positive control first: `.live` itself must reach every hook, or this
      // test would pass vacuously against a broken/no-op delegate installation.
      let live = LLMPolishStep.TelemetrySeams.live
      live.limbFailureObserved("ollama", "evict", "failed", "http_500", 42)
      live.breadcrumbStarted("live probe", nil)
      live.captureProviderInitError(LLMError.modelNotReady("probe"))
      live.captureAFMPolishError(LLMError.modelNotReady("probe"))
      live.breadcrumbCompleted("live probe", nil)
      live.recordPolishSkipped("openAI", "probe")
      #expect(
        recorder.telemetryEvents.count == 2, "live must fire limbFailureObserved + polishSkipped")
      #expect(
        recorder.breadcrumbMessages.count >= 2, "live must add breadcrumbs for started/completed")
      #expect(
        recorder.captureErrorCount == 2, "live must capture both provider-init and AFM errors")

      recorder.telemetryEvents.removeAll()
      recorder.breadcrumbMessages.removeAll()
      recorder.captureErrorCount = 0

      // Now the seam under test: silent(wrapping: .live) must reach NONE of them.
      let silent = LLMPolishStep.TelemetrySeams.silent(wrapping: .live)
      silent.limbFailureObserved("ollama", "evict", "failed", "http_500", 42)
      silent.breadcrumbStarted("silent probe", nil)
      silent.captureProviderInitError(LLMError.modelNotReady("probe"))
      silent.captureAFMPolishError(LLMError.modelNotReady("probe"))
      silent.breadcrumbCompleted("silent probe", nil)
      silent.recordPolishSkipped("openAI", "probe")

      #expect(
        recorder.telemetryEvents.isEmpty,
        "silent(wrapping: .live) leaked to TelemetryService: \(recorder.telemetryEvents)")
      #expect(
        recorder.breadcrumbMessages.isEmpty,
        "silent(wrapping: .live) leaked breadcrumbs: \(recorder.breadcrumbMessages)"
      )
      #expect(
        recorder.captureErrorCount == 0,
        "silent(wrapping: .live) leaked \(recorder.captureErrorCount) captureError call(s)")
    }
  #endif  // DEBUG

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
    let silentStep = makeStep(provider: .ollama, telemetry: .silent(wrapping: silentSpy.seams))
    silentStep.evictOllamaModel = { _ in failedOutcome }
    await silentStep.evictPreviousOllamaModel("some-model")
    #expect(silentSpy.limbFailureCalls.isEmpty)
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
