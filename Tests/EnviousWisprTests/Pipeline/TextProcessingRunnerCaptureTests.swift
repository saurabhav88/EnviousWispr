import EnviousWisprCore
import EnviousWisprLLM
import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

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
      let error: any Error
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
          error: error, category: category, stage: stage, extra: extra, tags: tags,
          fingerprintDetail: fingerprintDetail))
    }
  }

  /// Records every durable `llm.polish_failed` record the runner writes (#1446).
  /// Separate from `CaptureSpy` on purpose: the record fires for EVERY attempted
  /// failure while the alert fires only for the regression-capable subset, so a
  /// test can assert "the failure was counted AND nobody was paged."
  @MainActor
  final class RecordSpy {
    struct Call {
      let provider: String
      let model: String
      let reason: String
      let isTimeout: Bool
    }
    private(set) var calls: [Call] = []
    func sink(_ provider: String, _ model: String, _ reason: String, _ isTimeout: Bool) {
      calls.append(Call(provider: provider, model: model, reason: reason, isTimeout: isTimeout))
    }
  }

  /// Records every `llm.polish_skipped` the runner writes — polish that was never
  /// ATTEMPTED (#1055 / #1271 / #1305). The third seam; it must be silenced under
  /// crash recovery alongside the other two (#1446, cloud review of PR #1460).
  @MainActor
  final class SkipSpy {
    private(set) var calls: [(provider: String, reason: String)] = []
    func sink(_ provider: String, _ reason: String) {
      calls.append((provider: provider, reason: reason))
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
    // #1305: the .ollama entry gate consults a readiness probe before the
    // polisher. These are MID-FLIGHT-path tests (failure on a running server),
    // so the probe reports ready — and never touches a real network.
    step.ollamaReadinessProbe = { _ in .ready }
    return step
  }

  private func makeRunner(
    _ spy: CaptureSpy, _ records: RecordSpy = RecordSpy(), _ skips: SkipSpy = SkipSpy()
  ) -> TextProcessingRunner {
    // throwBelowSeconds 0.0 -> the executor runs every step (never injects a
    // timeout); the polisher's own throw drives the failure.
    let executor = FakeTimeoutExecutor(throwBelowSeconds: 0.0)
    return TextProcessingRunner(
      telemetry: .init(
        captureError: spy.sink, recordPolishFailed: records.sink,
        recordPolishSkipped: skips.sink),
      timeoutExecutor: executor.run)
  }

  // MARK: - Cloud / local classified failures

  @Test(
    "cloud rejected key -> 'rejected' notice, counted, no alert (the user's own key)",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "a revoked or mistyped user key is not an EnviousWispr defect")
  )
  func cloudKeyRejected() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") { LLMError.invalidAPIKey }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(
      result.polishError
        == "AI polish failed: OpenAI rejected your API key. Check or replace it in Settings.")
    #expect(spy.calls.isEmpty)
    #expect(records.calls.count == 1)
    #expect(records.calls.first?.reason == "api_key_rejected")
    #expect(records.calls.first?.provider == "openAI")
    #expect(records.calls.first?.model == "gpt-4o-mini")
    #expect(records.calls.first?.isTimeout == false)
  }

  /// The five reasons downgraded by founder directive 2026-07-09: each is caused by
  /// the user or the provider, so a GitHub issue would have nothing to fix. Their
  /// COUNT is the product signal (which walls do users hit), never an alert.
  nonisolated static let userAndProviderOwnedFailures: [(PolishFailureReason, String)] = [
    (.providerServerError, "provider_server_error"),
    (.accessDenied, "access_denied"),
    (.contentBlocked, "content_blocked"),
    (.inputTooLong, "input_too_long"),
    (.apiKeyRejected, "api_key_rejected"),
  ]

  @Test(
    "a user- or provider-caused failure is counted and never paged",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "these five filed GitHub issues about nothing"),
    arguments: userAndProviderOwnedFailures
  )
  func userAndProviderFailuresAreCountedNotPaged(
    reason: PolishFailureReason, tag: String
  ) async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") {
      LLMError.classified(reason)
    }

    _ = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(spy.calls.isEmpty, "\(reason) must never page us")
    #expect(records.calls.count == 1)
    #expect(records.calls.first?.reason == tag)
  }

  @Test(
    "cloud missing key -> skipped notice, counted, and NOBODY is paged",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "user-environment polish failures fired alerting Sentry errors")
  )
  func cloudKeyMissing() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    let step = makeStep(provider: .gemini, model: "gemini-2.0-flash") {
      LLMError.classified(.apiKeyMissing)
    }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    // The notice the user reads is untouched by the downgrade.
    #expect(
      result.polishError == "AI cleanup skipped: no Gemini API key set yet. Add one in Settings.")
    #expect(spy.calls.isEmpty)
    #expect(records.calls.count == 1)
    #expect(records.calls.first?.reason == "api_key_missing")
    #expect(records.calls.first?.provider == "gemini")
    #expect(records.calls.first?.model == "gemini-2.0-flash")
  }

  @Test(
    "cloud out-of-credits -> billing notice, counted, no alert (71 of 130 events)",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "user-environment polish failures fired alerting Sentry errors")
  )
  func cloudOutOfCredits() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") {
      LLMError.classified(.outOfCredits)
    }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(
      result.polishError
        == "AI polish failed: your OpenAI account is out of credits. Check your provider billing.")
    #expect(spy.calls.isEmpty)
    #expect(records.calls.first?.reason == "out_of_credits")
  }

  @Test(
    "Ollama unreachable -> Ollama notice, counted, no alert (the user's own machine)",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "user-environment polish failures fired alerting Sentry errors")
  )
  func ollamaUnreachable() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    let step = makeStep(provider: .ollama, model: "llama3.2") {
      LLMError.classified(.providerUnreachable)
    }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(
      result.polishError == "AI polish failed: Ollama isn't reachable. Start Ollama and try again.")
    #expect(spy.calls.isEmpty)
    #expect(records.calls.count == 1)
    #expect(records.calls.first?.reason == "provider_unreachable")
    #expect(records.calls.first?.provider == "ollama")
    #expect(records.calls.first?.model == "llama3.2")
  }

  // MARK: - Provider-awareness: the SAME reason, opposite channels

  @Test(
    "an offline user on a CLOUD provider is counted, never paged",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "cloud providerUnreachable alerted on the user's own network")
  )
  func cloudUnreachableIsCountedNotPaged() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    // What a real offline dictation throws, not a hand-made `.classified`.
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") {
      URLError(.notConnectedToInternet)
    }

    _ = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(spy.calls.isEmpty)
    #expect(records.calls.count == 1)
    #expect(records.calls.first?.reason == "provider_unreachable")
    #expect(records.calls.first?.provider == "openAI")
  }

  @Test(
    "a CLOUD model our catalog offered but the provider 404s pages us; the same on Ollama does not",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "model_unavailable conflated our dead catalog id with a model the user never pulled")
  )
  func cloudModelUnavailableAlertsButOllamaDoesNot() async throws {
    let cloudSpy = CaptureSpy()
    let cloudRecords = RecordSpy()
    let cloudStep = makeStep(provider: .gemini, model: "gemini-retired-model") {
      LLMError.classified(.modelUnavailable)
    }
    _ = try await makeRunner(cloudSpy, cloudRecords).run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [cloudStep])

    #expect(cloudSpy.calls.count == 1)
    #expect(cloudSpy.calls.first?.fingerprintDetail == "model_unavailable")
    #expect(cloudRecords.calls.count == 1)

    let localSpy = CaptureSpy()
    let localRecords = RecordSpy()
    let localStep = makeStep(provider: .ollama, model: "never-pulled") {
      LLMError.classified(.modelUnavailable)
    }
    _ = try await makeRunner(localSpy, localRecords).run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [localStep])

    #expect(localSpy.calls.isEmpty)
    #expect(localRecords.calls.count == 1)
    #expect(localRecords.calls.first?.reason == "model_unavailable")
  }

  @Test("a stored-but-unreadable key pages us with its own fingerprint")
  func apiKeyUnreadableAlerts() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    let step = makeStep(provider: .gemini, model: "gemini-2.0-flash") {
      LLMError.classified(.apiKeyUnreadable)
    }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    // Same sentence the no-key user reads; a different fingerprint for us.
    #expect(
      result.polishError == "AI cleanup skipped: no Gemini API key set yet. Add one in Settings.")
    #expect(spy.calls.count == 1)
    #expect(spy.calls.first?.fingerprintDetail == "api_key_unreadable")
    #expect(records.calls.first?.reason == "api_key_unreadable")
  }

  @Test("a malformed request pages us with an unchanged fingerprint")
  func badRequestAlerts() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") {
      LLMError.classified(.badRequest)
    }

    _ = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(spy.calls.count == 1)
    let call = try #require(spy.calls.first)
    #expect(call.category == .polishProviderFailed)
    #expect(call.stage == "polish")
    #expect(call.fingerprintDetail == "bad_request")
    #expect(records.calls.first?.reason == "bad_request")
  }

  @Test(
    "an unrecognized URLError pages us with a stable fingerprint through the real capture path (#1525 PR I-C)"
  )
  func unrecognizedURLErrorAlertsWithStableFingerprint() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    // .badURL is not in PolishFailureReason.from's recognized connectivity-code
    // set (PolishFailureReason.swift:345-352), so it falls to `.unknown` — the
    // alerting channel, unlike .notConnectedToInternet's `.providerUnreachable`
    // in `cloudUnreachableIsCountedNotPaged` above.
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") { URLError(.badURL) }

    _ = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(spy.calls.count == 1)
    let call = try #require(spy.calls.first)
    #expect(call.category == .polishProviderFailed)
    #expect(call.fingerprintDetail == "unknown")
    #expect(records.calls.first?.reason == "unknown")

    // Runtime proof on the supported macOS Swift/Foundation toolchain (#1525 PR I-C):
    // boxing `URLError` as `any Error` produces an `NSError` dynamic value, so a
    // `StableSentryErrorIdentity` conformance is unreachable through this path.
    // The existing `NSError` fallback already produces the stable descriptor.
    //
    // #1525 PR J-1: `makeHandledErrorEvent` is now narrowed, so the spy-captured
    // raw error must go through the SAME normalization the runner's `.live` seam
    // applies before calling it — proving the boundary preserves this exact
    // historical fingerprint, not a fresh assumption about what it does.
    let normalized = SentryCaptureBoundaryError.normalizingGenerationFailure(call.error)
    let event = SentryBreadcrumb.makeHandledErrorEvent(
      normalized, category: call.category, stage: call.stage, extra: call.extra,
      tags: call.tags, fingerprintDetail: call.fingerprintDetail, environment: "test")
    #expect(
      event.fingerprint == [
        "handled_error", "polish_provider_failed", "NSURLErrorDomain#-1000", "unknown", "test",
      ])
    #expect(event.tags?["error.identity"] == "polish.external_url_transport")
  }

  @Test(
    "an unrecognized non-URLError error normalizes to .unexpectedGenerationFailure (#1525 PR J-1)"
  )
  func unrecognizedNonURLErrorNormalizesToUnexpectedGenerationFailure() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    struct OpaqueError: Error {}
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") { OpaqueError() }

    _ = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(spy.calls.count == 1)
    let call = try #require(spy.calls.first)
    let normalized = SentryCaptureBoundaryError.normalizingGenerationFailure(call.error)
    #expect(normalized.sentrySemanticID == "boundary.unexpected_generation_failure")
  }

  // MARK: - Timeout

  @Test("runner polish-budget timeout -> timed_out tag + is_timeout=true")
  func polishTimeout() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    // Polish step's cloud budget is 5s; throwing below 6s injects a TimeoutError
    // for it (the executor short-circuits before calling the polisher).
    let executor = FakeTimeoutExecutor(throwBelowSeconds: 6.0)
    let runner = TextProcessingRunner(
      telemetry: .init(
        captureError: spy.sink, recordPolishFailed: records.sink,
        recordPolishSkipped: { _, _ in }),
      timeoutExecutor: executor.run)
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") {
      LLMError.requestFailed("unused")
    }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(spy.calls.count == 1)
    #expect(spy.calls.first?.tags["polish.error_case"] == "timed_out")
    #expect(spy.calls.first?.tags["polish.is_timeout"] == "true")
    #expect(result.polishError?.hasPrefix("AI cleanup skipped:") == true)
    // #1446: `is_timeout` reaches the durable record too, not only the alert.
    #expect(records.calls.count == 1)
    #expect(records.calls.first?.reason == "timed_out")
    #expect(records.calls.first?.isTimeout == true)
  }

  // MARK: - Apple Intelligence is excluded

  @Test("Apple Intelligence keeps today's exact wording and fires NO runner capture")
  func appleIntelligenceExcluded() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    let step = makeStep(provider: .appleIntelligence, model: "apple-intelligence") {
      LLMError.requestFailed("boom")
    }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(
      result.polishError == "AI polish failed: "
        + LLMError.requestFailed("boom").localizedDescription)
    // The alerting capture for on-device polish is owned by the polish step
    // (`captureAFMPolishError`), never by the runner.
    #expect(spy.calls.isEmpty)
    // #1446: ...but the durable COUNT is the runner's, or `llm.polish_failed`
    // would not partition live polish outcomes (AFM successes emit
    // `llm.polish_completed`).
    #expect(records.calls.count == 1)
    #expect(records.calls.first?.provider == "appleIntelligence")
    #expect(records.calls.first?.model == "apple-intelligence")
    #expect(records.calls.first?.reason == "bad_request")
  }

  @Test(
    "an Apple Intelligence model-not-ready failure is counted as model_unavailable",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "surfaced Apple Intelligence failures were absent from llm.polish_failed")
  )
  func appleIntelligenceModelNotReadyIsCounted() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    let step = makeStep(provider: .appleIntelligence, model: "apple-intelligence") {
      LLMError.modelNotReady("still downloading")
    }

    _ = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(spy.calls.isEmpty)
    #expect(records.calls.count == 1)
    #expect(records.calls.first?.reason == "model_unavailable")
  }

  /// The on-device skips that degrade quietly to raw text (#1080, #1055): a Mac
  /// that cannot run Apple Intelligence at all, and the per-request language gates.
  /// #1448: all three now ALSO emit a `llm.polish_skipped` tag (they previously
  /// emitted nothing at all — the exact gap #1448 fixes).
  nonisolated static let silentAFMSkips: [(LLMError, String)] = [
    (.frameworkUnavailable("pre-macOS-26"), "framework_unavailable"),
    (.unsupportedInputLanguage("de"), "unsupported_input_language"),
    (.outputLanguageDrift(expected: "en", actual: "de"), "output_language_drift"),
  ]

  @Test(
    "a SILENT Apple Intelligence skip is counted as a failure by nothing, but now emits its skip tag",
    arguments: silentAFMSkips)
  func appleIntelligenceSilentSkipsAreNotCounted(error: LLMError, tag: String) async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let skips = SkipSpy()
    let runner = makeRunner(spy, records, skips)
    let step = makeStep(provider: .appleIntelligence, model: "apple-intelligence") { error }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    // Raw deterministic text, no pill, and no FAILURE reported: these degrade
    // quietly by design (#1080, #1055). Counting them as failures would inflate
    // the failure rate.
    #expect(result.polishError == nil)
    #expect(spy.calls.isEmpty)
    #expect(records.calls.isEmpty)
    // #1448: but a skip tag now DOES fire, so the previously-null
    // `dictation.completed.llm_provider` for these dictations gets a reason.
    #expect(skips.calls.count == 1)
    #expect(skips.calls.first?.provider == "appleIntelligence")
    #expect(skips.calls.first?.reason == tag)
  }

  @Test(
    "provider attribution comes from PolishSkipReason, never a stale runner-side snapshot",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1448",
      "a runner-side provider snapshot taken before the step's own, later snapshot could diverge from it"
    )
  )
  func providerAttributionSurvivesRunnerToStepHandoff() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let skips = SkipSpy()
    let runner = makeRunner(spy, records, skips)
    // Configured as .openAI when the runner takes its pre-await snapshot
    // (`polishProviderAtStart`); `onWillProcess` then flips it to `.egOne`
    // BEFORE the step takes its OWN, later snapshot inside `process()`. With
    // `egOneRuntime` nil, the step throws `.egOneSkipped(.notReady)`. If the
    // emitted provider still came from the runner's stale snapshot, this would
    // wrongly report "openAI" instead of "egOne".
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") {
      LLMError.egOneSkipped(.notReady)
    }
    step.llmProvider = .openAI
    step.onWillProcess = { step.llmProvider = .egOne }

    _ = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(spy.calls.isEmpty)
    #expect(records.calls.isEmpty)
    #expect(skips.calls.count == 1)
    #expect(skips.calls.first?.provider == "egOne")
    #expect(skips.calls.first?.reason == "local_polish_not_ready")
  }

  // MARK: - Existing 11 tags unchanged after consolidation

  @Test(
    "context-window and Ollama-preflight skip tags are byte-identical after routing through PolishSkipReason"
  )
  func existingSkipTagsUnchanged() async throws {
    // Context-window predicted / caught (#1055).
    for (stage, tag) in [
      (AFMContextWindowExceeded.Stage.predicted, "context_window_predicted"),
      (.caught, "context_window_caught"),
    ] {
      let skips = SkipSpy()
      let runner = makeRunner(CaptureSpy(), RecordSpy(), skips)
      let step = makeStep(provider: .appleIntelligence, model: "apple-intelligence") {
        AFMContextWindowExceeded(stage: stage)
      }
      _ = try await runner.run(
        rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])
      #expect(skips.calls.count == 1)
      #expect(skips.calls.first?.provider == "appleIntelligence")
      #expect(skips.calls.first?.reason == tag)
    }

    // Ollama preflight not-ready (#1305): server down / model missing.
    for (readiness, tag) in [
      (OllamaReadiness.serverDown, "local_polish_ollama_server_down"),
      (.modelMissing, "local_polish_ollama_model_missing"),
    ] {
      let skips = SkipSpy()
      let runner = makeRunner(CaptureSpy(), RecordSpy(), skips)
      let step = makeStep(provider: .ollama, model: "llama3.2") {
        LLMError.requestFailed("unused")
      }
      step.ollamaReadinessProbe = { _ in readiness }
      _ = try await runner.run(
        rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])
      #expect(skips.calls.count == 1)
      #expect(skips.calls.first?.provider == "ollama")
      #expect(skips.calls.first?.reason == tag)
    }
  }

  @Test(
    "an Apple Intelligence timeout routes its skip through the seam, not TelemetryService",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "llm.polish_skipped bypassed the seams and leaked from crash recovery")
  )
  func appleIntelligenceTimeoutSkipRoutesThroughTheSeam() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let skips = SkipSpy()
    // AFM's polish budget is 10s; throwing below 11s injects a TimeoutError.
    let executor = FakeTimeoutExecutor(throwBelowSeconds: 11.0)
    let runner = TextProcessingRunner(
      telemetry: .init(
        captureError: spy.sink, recordPolishFailed: records.sink,
        recordPolishSkipped: skips.sink),
      timeoutExecutor: executor.run)
    let step = makeStep(provider: .appleIntelligence, model: "apple-intelligence") {
      LLMError.requestFailed("unused")
    }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    // An on-device timeout on a long dictation degrades quietly to raw text.
    #expect(result.polishError == nil)
    #expect(spy.calls.isEmpty)
    #expect(records.calls.isEmpty)  // never attempted-and-failed; it was skipped
    #expect(skips.calls.count == 1)
    #expect(skips.calls.first?.provider == "appleIntelligence")
    #expect(skips.calls.first?.reason == "context_window_timeout")
  }

  // MARK: - No-false-positive boundary

  @Test("a cancelled cloud request fires no telemetry and surfaces no notice")
  func cancellationLikeIgnored() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    let step = makeStep(provider: .openAI, model: "gpt-4o-mini") { URLError(.cancelled) }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(result.polishError == nil)
    #expect(spy.calls.isEmpty)
    // A torn-down request is not an attempted-and-failed polish.
    #expect(records.calls.isEmpty)
  }

  @Test("a successful polish fires neither runner-owned skip nor failure telemetry")
  func successNoCapture() async throws {
    let spy = CaptureSpy()
    let records = RecordSpy()
    let skips = SkipSpy()
    let runner = makeRunner(spy, records, skips)
    let step = LLMPolishStep(keychainManager: KeychainManager())
    step.llmProvider = .openAI
    step.llmModel = "gpt-4o-mini"
    step.makePolisher = { _, _, _ in SucceedingPolisher() }

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil, steps: [step])

    #expect(result.polishError == nil)
    #expect(spy.calls.isEmpty)
    #expect(records.calls.isEmpty)
    #expect(skips.calls.isEmpty)
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

  // MARK: - Output truncation contract (#1710) — RED-first against chunk-1 HEAD

  @Test("truncated cloud polish -> complete pre-polish text, one count, no alert")
  func outputTruncatedContract() async throws {
    // Written with a dynamic rawValue lookup during the RED phase; now the
    // typed case is injected directly (per chunk-2 review).
    let spy = CaptureSpy()
    let records = RecordSpy()
    let runner = makeRunner(spy, records)
    let step = makeStep(provider: .gemini, model: "gemini-2.5-flash") {
      LLMError.classified(.outputTruncated)
    }
    // Downstream recorder: proves the COMPLETE pre-polish text continues to
    // the next step after the rejected polish (plan §11 contract).
    let downstream = RecordingStep()

    let result = try await runner.run(
      rawText: Self.longTranscript, language: "en", targetAppName: nil,
      steps: [step, downstream])

    // Complete pre-polish text retained exactly; no partial output accepted.
    #expect(result.context.text == Self.longTranscript)
    #expect(downstream.receivedText == Self.longTranscript)
    #expect(result.context.polishedText == nil)
    #expect(result.context.llmProvider == nil)
    #expect(result.context.llmModel == nil)
    // Exact composed notice.
    #expect(
      result.polishError
        == "AI polish failed: Gemini ended the response before cleanup finished. "
        + "EnviousWispr kept your complete original text instead. If this keeps happening, "
        + "choose another model or use a shorter dictation.")
    // Exactly one durable count with the right attribution; zero alerts.
    #expect(spy.calls.isEmpty)
    #expect(records.calls.count == 1)
    #expect(records.calls.first?.reason == "output_truncated")
    #expect(records.calls.first?.provider == "gemini")
    #expect(records.calls.first?.model == "gemini-2.5-flash")
    #expect(records.calls.first?.isTimeout == false)
  }


  /// Pass-through step that records the text it receives, proving the
  /// pipeline continues downstream with the complete pre-polish text after
  /// a rejected polish (#1710).
  private final class RecordingStep: TextProcessingStep {
    let name = "Downstream Recorder"
    let isEnabled = true
    let maxDuration: Duration = .seconds(5)
    private(set) var receivedText: String?

    func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
      receivedText = context.text
      return context
    }
  }

}
