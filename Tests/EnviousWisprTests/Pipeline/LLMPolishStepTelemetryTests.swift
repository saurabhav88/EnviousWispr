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
    private(set) var skipCalls: [(provider: String, reason: String, takeID: String?)] = []

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
        recordPolishSkipped: { provider, reason, takeID in
          self.skipCalls.append((provider, reason, takeID))
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
    "too-short bypass (CJK char-count path) emits its own skip tag with the take key; started already fired, nothing else does"
  )
  func tooShortBypassCJK() async throws {
    let spy = Spy()
    let step = makeStep(provider: .openAI, telemetry: spy.seams)
    var context = TextProcessingContext(text: "短い", language: "ja")
    // #1846: this route returns from `process()` BEFORE the runner sees it, so the
    // step's own seam family is the only thing that can carry the key here. The
    // runner-side test cannot cover it.
    context.takeID = "9f2c1d84-6b3a-4e07-9c51-0a7d2e6f1b33"

    _ = try await step.process(context)

    #expect(spy.startedCalls.count == 1)
    #expect(spy.skipCalls.count == 1)
    let skip = try #require(spy.skipCalls.first)
    #expect(skip.provider == "openAI")
    #expect(skip.reason == "too_short")
    #expect(skip.takeID == "9f2c1d84-6b3a-4e07-9c51-0a7d2e6f1b33")
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
      live.recordPolishSkipped("openAI", "probe", nil)
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
      silent.recordPolishSkipped("openAI", "probe", nil)

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

  /// #2061: `evictPreviousOllamaModel` now asks the daemon whether the model is
  /// installed before attempting the unload, so every eviction test must state
  /// which world it is in. Without this the default probe would reach real
  /// localhost and the result would depend on whether Ollama happens to be
  /// running on the machine executing the suite.
  private static let daemonReady: @MainActor (String) async -> OllamaReadiness = { _ in
    .ready(facts: OllamaModelFacts(isRemote: false, thinks: nil))
  }

  @Test("limb-health metric fires on a failed eviction, with `.live`; silent with `.silent`")
  func limbFailureObservedIsDeterministic() async throws {
    let failedOutcome = OllamaEvictOutcome(result: "failed", durationMs: 42, reason: "http_500")

    let spy = Spy()
    let liveStep = makeStep(provider: .ollama, telemetry: spy.seams)
    liveStep.ollamaReadinessProbe = Self.daemonReady
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
    silentStep.ollamaReadinessProbe = Self.daemonReady
    silentStep.evictOllamaModel = { _ in failedOutcome }
    await silentStep.evictPreviousOllamaModel("some-model")
    #expect(silentSpy.limbFailureCalls.isEmpty)
  }

  @Test("a successful eviction never fires the limb metric, `.live` or `.silent`")
  func limbFailureObservedSkipsOnSuccess() async throws {
    let successOutcome = OllamaEvictOutcome(result: "unloaded", durationMs: 10, reason: "http_200")
    let spy = Spy()
    let step = makeStep(provider: .ollama, telemetry: spy.seams)
    step.ollamaReadinessProbe = Self.daemonReady
    step.evictOllamaModel = { _ in successOutcome }

    await step.evictPreviousOllamaModel("some-model")

    #expect(spy.limbFailureCalls.isEmpty)
  }

  // MARK: - #2061: the eviction is gated on the daemon's own answer

  /// The noise this removes. `-1004` (daemon unreachable) was 202 events across
  /// 133 users in 90 days and `http_404` (model not installed) another 44 across
  /// 39, against 27 users who have ever polished with Ollama at all. Both are
  /// unloads aimed at weights that cannot exist, and both sat above the genuine
  /// stuck-model case in any "what is failing most" query.
  /// `nonisolated` because `@Test(arguments:)` is evaluated outside the suite's
  /// `@MainActor` isolation (`swift-testing-patterns.md`
  /// RULE: swift-testing-mainactor-arguments-needs-nonisolated).
  nonisolated static let noWeightsResident: [OllamaReadiness] = [
    .daemonUnreachable, .modelMissing, .noModelSelected,
  ]

  @Test(
    "an unreachable daemon or an uninstalled model sends no unload and reports nothing",
    arguments: noWeightsResident)
  func evictionIsSkippedWhenThereAreNoWeightsToUnload(readiness: OllamaReadiness) async {
    let spy = Spy()
    let step = makeStep(provider: .ollama, telemetry: spy.seams)
    step.ollamaReadinessProbe = { _ in readiness }

    // Counts REQUESTS, not just telemetry: suppressing the event while still
    // spending the round trip would pass a telemetry-only assertion and leave
    // the second half of the defect in place.
    let requests = RequestCounter()
    step.evictOllamaModel = { _ in
      requests.bump()
      return OllamaEvictOutcome(result: "failed", durationMs: 1, reason: "-1004")
    }

    await step.evictPreviousOllamaModel("qwen2.5:3b")

    #expect(requests.count == 0, "no unload may be sent when nothing can be resident")
    #expect(spy.limbFailureCalls.isEmpty, "and therefore nothing to report")
  }

  /// The two-way control, and the case #286 actually cares about: the daemon is
  /// up, the model IS installed, and the unload is refused. That must still
  /// report, or this fix would have traded the noise for the signal.
  @Test("a refused unload on a live daemon still reports, unchanged")
  func genuineEvictionFailureStillReports() async {
    let spy = Spy()
    let step = makeStep(provider: .ollama, telemetry: spy.seams)
    step.ollamaReadinessProbe = Self.daemonReady

    let requests = RequestCounter()
    step.evictOllamaModel = { _ in
      requests.bump()
      return OllamaEvictOutcome(result: "failed", durationMs: 42, reason: "http_500")
    }

    await step.evictPreviousOllamaModel("qwen2.5:3b")

    #expect(requests.count == 1, "a live daemon must still be asked to unload")
    #expect(spy.limbFailureCalls.count == 1)
    #expect(spy.limbFailureCalls.first?.cat == "http_500")
  }

  /// The conservative half, and the reason `.serverDown` is NOT in the list
  /// above (cloud review, PR #2071). `.serverDown` means something IS listening
  /// and answered unusably — a non-2xx, an unparseable body, or a blown 1s
  /// deadline. None of those prove the model is unloaded, and a busy daemon is
  /// exactly the state a large resident model produces, so treating it as "safe
  /// to skip" would drop the unload precisely in the #286 case.
  @Test("an ambiguous daemon answer still evicts, because it is not proof")
  func ambiguousReadinessStillEvicts() async {
    let spy = Spy()
    let step = makeStep(provider: .ollama, telemetry: spy.seams)
    step.ollamaReadinessProbe = { _ in .serverDown }

    let requests = RequestCounter()
    step.evictOllamaModel = { _ in
      requests.bump()
      return OllamaEvictOutcome(result: "failed", durationMs: 7, reason: "http_500")
    }

    await step.evictPreviousOllamaModel("qwen2.5:3b")

    #expect(requests.count == 1, "no proof of absence means the unload must still be attempted")
    #expect(spy.limbFailureCalls.count == 1, "and a genuine failure must still report")
  }

  /// The decision function directly, exhaustively. The eviction tests above
  /// cover the wiring; this pins the POLICY, so a new `OllamaReadiness` case
  /// cannot quietly inherit "safe to skip" — the direction that costs a #286
  /// regression rather than a redundant localhost request.
  @Test("only proven-no-residency answers may skip the unload")
  func skipPolicyIsProofOnly() {
    #expect(LLMPolishStep.evictionIsProvablyUnnecessary(.daemonUnreachable))
    #expect(LLMPolishStep.evictionIsProvablyUnnecessary(.modelMissing))
    #expect(LLMPolishStep.evictionIsProvablyUnnecessary(.noModelSelected))
    #expect(LLMPolishStep.evictionIsProvablyUnnecessary(.serverDown) == false)
    #expect(
      LLMPolishStep.evictionIsProvablyUnnecessary(
        .ready(facts: OllamaModelFacts(isRemote: false, thinks: nil))) == false)
  }

  /// A remote model reaches `.ready` too (the daemon lists it in `/api/tags`),
  /// so the readiness gate deliberately does NOT subsume the #1914
  /// proven-remote suppression in `PipelineSettingsSync`. Pinned so a later
  /// reader does not delete one believing the other covers it.
  @Test("readiness does not answer the remote question the settings gate answers")
  func readinessDoesNotSubsumeTheRemoteSkip() async {
    let spy = Spy()
    let step = makeStep(provider: .ollama, telemetry: spy.seams)
    step.ollamaReadinessProbe = { _ in
      .ready(facts: OllamaModelFacts(isRemote: true, thinks: nil))
    }
    let requests = RequestCounter()
    step.evictOllamaModel = { _ in
      requests.bump()
      return OllamaEvictOutcome(result: "unloaded", durationMs: 5, reason: "http_200")
    }

    await step.evictPreviousOllamaModel("deepseek-v4-flash:latest")

    #expect(
      requests.count == 1,
      "a remote model passes THIS gate; suppressing it is PipelineSettingsSync's job")
  }

  final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
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
