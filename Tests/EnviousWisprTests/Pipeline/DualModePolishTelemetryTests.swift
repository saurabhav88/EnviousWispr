import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

/// Tests for AFM polish telemetry plumbing (#429; the dual `router_mode` /
/// `router_basis` fields were removed in #1072 when the natural/technical router
/// was collapsed into a single prompt).
///
/// Coverage strategy: AppleIntelligenceConnector cannot be tested directly
/// (requires AFM macOS 26+), but `LLMPolishStep.makePolisher` IS an injectable
/// seam (#827 PR-8) that lets a canned polisher drive `process()` end-to-end
/// on both the AFM and planner code paths without needing the real
/// connector. #1624: `pipelineFellBackToRawIsOR` below now uses this seam.
/// This suite also verifies:
///
///   1. PolishMetadata wraps cleanly into LLMResult (now filter-only fields).
///   2. ExecutionMetrics decodes old-shape records (Codable backward-compat).
///   3. TelemetryService.llmPolishCompleted forwards the filter/fallback
///      properties through the testEventHook seam.
///   4. EnviousOutputFilter trips deterministically (fixed input/output pairs).
///   4b. The OR formula `pipelineFellBackToRaw = filter || validator`.
///   4c. The pipeline-side degradation `metadata == nil ? nil : pipelineFellBackToRaw`.
///   5. AFMPolishError wraps the underlying error, and `captureAFMPolishError`
///      records a `generationFailed` / `polish` Sentry event — except for a
///      cancellation, which is downgraded to a breadcrumb (#1438).
///   7. #1050 `polishFallbackReason` honest disaggregation.
@MainActor
@Suite("AFM polish telemetry — #1072")
struct DualModePolishTelemetryTests {

  // MARK: - 1. LLMResult ↔ PolishMetadata wrapping

  @Test("LLMResult initializer omits metadata by default for cloud providers")
  func llmResultDefaultMetadataIsNil() {
    let result = LLMResult(polishedText: "hello")
    #expect(result.polishMetadata == nil)
  }

  @Test("LLMResult preserves PolishMetadata when constructed with one")
  func llmResultPreservesMetadata() {
    let meta = PolishMetadata(
      filterTripped: "code_shape_guard",
      filterFellBackToRaw: true
    )
    let result = LLMResult(polishedText: "hello", polishMetadata: meta)
    #expect(result.polishMetadata?.filterTripped == "code_shape_guard")
    #expect(result.polishMetadata?.filterFellBackToRaw == true)
  }

  // MARK: - 2. ExecutionMetrics Codable backward-compat

  @Test("ExecutionMetrics decodes old-shape records (without polish* fields) cleanly")
  func executionMetricsBackwardCompat() throws {
    let oldShape = """
      {
        "asrLatencySeconds": 0.5,
        "llmLatencySeconds": 1.2,
        "coldStart": false,
        "streamingMode": false
      }
      """
    let data = oldShape.data(using: .utf8)!
    let metrics = try JSONDecoder().decode(ExecutionMetrics.self, from: data)
    #expect(metrics.asrLatencySeconds == 0.5)
    #expect(metrics.llmLatencySeconds == 1.2)
    #expect(metrics.polishFilterTripped == nil)
    #expect(metrics.polishFellBackToRaw == nil)
  }

  @Test("ExecutionMetrics decodes legacy records that still carry router fields cleanly")
  func executionMetricsIgnoresLegacyRouterFields() throws {
    // Records persisted before #1072 still have polishRouterMode / polishRouterBasis
    // on disk. Decoding must ignore the now-unknown keys, not fail.
    let legacy = """
      {
        "coldStart": false,
        "streamingMode": false,
        "polishRouterMode": "technical",
        "polishRouterBasis": "tier1",
        "polishFilterTripped": "imperative_execution_guard",
        "polishFellBackToRaw": true
      }
      """
    let metrics = try JSONDecoder().decode(
      ExecutionMetrics.self, from: legacy.data(using: .utf8)!)
    #expect(metrics.polishFilterTripped == "imperative_execution_guard")
    #expect(metrics.polishFellBackToRaw == true)
  }

  @Test("ExecutionMetrics roundtrips polish* fields through Codable")
  func executionMetricsRoundtripsPolishFields() throws {
    let original = ExecutionMetrics(
      llmLatencySeconds: 1.0,
      polishFilterTripped: "imperative_execution_guard",
      polishFellBackToRaw: true
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ExecutionMetrics.self, from: encoded)
    #expect(decoded.polishFilterTripped == "imperative_execution_guard")
    #expect(decoded.polishFellBackToRaw == true)
  }

  // MARK: - 3. TelemetryService surfaces properties via testEventHook

  // testEventHook + CapturedTelemetryEvent are DEBUG-only — release builds
  // strip them from TelemetryService entirely. CI compiles tests with
  // `swift-test.sh -c release`, so these tests must be DEBUG-gated to
  // compile in both flavors. Coverage is preserved in dev test runs.
  #if DEBUG

    @Test("TelemetryService emits the filter properties when populated")
    func telemetryServiceEmitsNewProperties() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.llmPolishCompleted(
        provider: "appleIntelligence",
        model: "apple-intelligence",
        result: "success",
        latencySeconds: 0.873,
        filterTripped: "code_shape_guard",
        fellBackToRaw: true
      )

      let event = try await waiter.waitForEvent(named: "llm.polish_completed")
      #expect(event.stringProps["provider"] == "appleIntelligence")
      #expect(event.stringProps["router_mode"] == nil)
      #expect(event.stringProps["filter_tripped"] == "code_shape_guard")
      #expect(event.boolProps["fell_back_to_raw"] == true)
    }

    @Test("TelemetryService omits polish properties for cloud providers (nil params)")
    func telemetryServiceOmitsForCloudProvider() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.llmPolishCompleted(
        provider: "openai", model: "gpt-4o-mini",
        result: "success", latencySeconds: 1.2
      )

      let event = try await waiter.waitForEvent(named: "llm.polish_completed")
      #expect(event.stringProps["provider"] == "openai")
      #expect(event.stringProps["filter_tripped"] == nil)
      #expect(event.boolProps["fell_back_to_raw"] == nil)
    }

    @Test("TelemetryService emits fell_back_to_raw=false distinctly from absent")
    func telemetryServiceEmitsFalseFellBack() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.llmPolishCompleted(
        provider: "appleIntelligence", model: "apple-intelligence",
        result: "success", latencySeconds: 0.5,
        filterTripped: nil,
        fellBackToRaw: false
      )

      let event = try await waiter.waitForEvent(named: "llm.polish_completed")
      #expect(event.boolProps["fell_back_to_raw"] == false)
      // filter_tripped absent (passed nil) — schema cleanliness
      #expect(event.stringProps["filter_tripped"] == nil)
    }

  #endif  // DEBUG (testEventHook tests)

  // MARK: - 4. EnviousOutputFilter deterministic trip

  @Test(
    "EnviousOutputFilter trips imperative_execution_guard when trigger present and required token missing"
  )
  func filterTripsImperativeGuardDeterministically() {
    // Trigger from EnviousOutputFilter.swift:152: "convert this into json"
    // Required token for trigger: "convert". Output omits "convert" so the guard fires.
    let input = "Please convert this into json for me"
    let output = "Here is the JSON output: { \"key\": 1 }"

    let filtered = EnviousOutputFilter.filter(input: input, output: output)
    #expect(filtered.fellBackToRaw == true)
    #expect(filtered.tripped == "imperative_execution_guard")
    #expect(filtered.polished == input.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  @Test(
    "EnviousOutputFilter does NOT trip imperative guard when required token is preserved in output")
  func filterDoesNotTripImperativeWhenTokenPreserved() {
    // Same trigger but output contains "convert" — guard should not fire.
    let input = "Please convert this into json for me"
    let output = "Please convert this into JSON for me."

    let filtered = EnviousOutputFilter.filter(input: input, output: output)
    #expect(filtered.tripped != "imperative_execution_guard")
  }

  @Test("EnviousOutputFilter trips code_shape_guard on code-output for non-code input")
  func filterTripsCodeShapeGuard() {
    let input = "hello there can you help me"
    let output = "```python\ndef hello():\n    print('hi')\n```"

    let filtered = EnviousOutputFilter.filter(input: input, output: output)
    #expect(filtered.fellBackToRaw == true)
    #expect(filtered.tripped == "code_shape_guard")
    #expect(filtered.polished == input)
  }

  // MARK: - 4b. PipelineFellBackToRaw OR semantics (LLMPolishStep §3.5)

  /// The real OR formula is duplicated on two separate code paths in
  /// `LLMPolishStep.process()` — the AFM branch and the planner/cloud branch
  /// (#1624 grounded review) — so this drives BOTH providers through the real
  /// `makePolisher` seam across all 4 filter-fallback x validator-rejection
  /// combinations, rather than recomputing the OR locally.
  private struct CannedResultPolisher: TranscriptPolisher {
    let result: LLMResult

    func polish(
      text: String,
      instructions: PolishInstructions,
      config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      result
    }
  }

  @Test(
    "pipelineFellBackToRaw uses the real OR on AFM and planner paths",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1624",
      "fallback tests recomputed their own oracle"
    )
  )
  func pipelineFellBackToRawIsOR() async throws {
    let original = "please clean up this sentence for the release notes"
    let validPolish = "Please clean up this sentence for the release notes."
    let rejectedPolish = String(repeating: "hallucinated expansion ", count: 40)

    for provider in [LLMProvider.appleIntelligence, .openAI] {
      for filterFellBack in [false, true] {
        for validatorRejected in [false, true] {
          let result = LLMResult(
            polishedText: validatorRejected ? rejectedPolish : validPolish,
            polishMetadata: PolishMetadata(
              filterTripped: filterFellBack ? "test_guard" : nil,
              filterFellBackToRaw: filterFellBack)
          )

          let step = LLMPolishStep(keychainManager: KeychainManager(), telemetry: .silent())
          step.llmProvider = provider
          step.llmModel = provider == .appleIntelligence ? "apple-intelligence" : "gpt-4o-mini"
          step.makePolisher = { _, _, _ in CannedResultPolisher(result: result) }

          let context = try await step.process(
            TextProcessingContext(text: original, language: "en"))

          #expect(
            context.polishedText == (validatorRejected ? original : validPolish),
            "provider \(provider), filterFellBack=\(filterFellBack), validatorRejected=\(validatorRejected)"
          )
          #expect(
            context.pipelineFellBackToRaw == (filterFellBack || validatorRejected),
            "provider \(provider), filterFellBack=\(filterFellBack), validatorRejected=\(validatorRejected)"
          )
        }
      }
    }
  }

  // MARK: - 7. #1050 polishFallbackReason — honest disaggregation

  /// The real production helper (`LLMPolishStep.polishFallbackReason`) is pure +
  /// static, so we exercise it directly rather than re-implementing the logic.

  @Test("polishFallbackReason: nil when polish CHANGED the text (not a fallback)")
  func fallbackReasonNilWhenChanged() {
    // Obviously-distinct strings: filler removed + capitalized + punctuated, so
    // validatedText != originalText → polish applied → not a fallback.
    let reason = LLMPolishStep.polishFallbackReason(
      filterFellBackToRaw: false,
      postFilterOutput: "This is the clean text.",
      validatedText: "This is the clean text.",
      originalText: "um so this is the clean text")
    #expect(reason == nil)
  }

  @Test("polishFallbackReason: guard_discard when the connector filter tripped")
  func fallbackReasonGuardDiscard() {
    // filter trip → postFilterOutput is raw input, validated == original.
    let reason = LLMPolishStep.polishFallbackReason(
      filterFellBackToRaw: true,
      postFilterOutput: "raw input",
      validatedText: "raw input",
      originalText: "raw input")
    #expect(reason == "guard_discard")
  }

  @Test("polishFallbackReason: guard_discard takes PRECEDENCE even if output differs")
  func fallbackReasonGuardDiscardPrecedence() {
    // Defensive: a filter trip must win before the no_change/validator branch,
    // since on a real trip postFilterOutput == input anyway.
    let reason = LLMPolishStep.polishFallbackReason(
      filterFellBackToRaw: true,
      postFilterOutput: "something else",
      validatedText: "raw input",
      originalText: "raw input")
    #expect(reason == "guard_discard")
  }

  @Test("polishFallbackReason: no_change when the model returned the input unchanged")
  func fallbackReasonNoChange() {
    let reason = LLMPolishStep.polishFallbackReason(
      filterFellBackToRaw: false,
      postFilterOutput: "already clean text",
      validatedText: "already clean text",
      originalText: "already clean text")
    #expect(reason == "no_change")
  }

  @Test("polishFallbackReason: validator_discard when the validator substituted the original")
  func fallbackReasonValidatorDiscard() {
    // Model produced DIFFERENT output, but validatePolishOutput rejected it and
    // returned the original — invisible to filter_tripped.
    let reason = LLMPolishStep.polishFallbackReason(
      filterFellBackToRaw: false,
      postFilterOutput: "a wildly hallucinated expansion",
      validatedText: "original",
      originalText: "original")
    #expect(reason == "validator_discard")
  }

  @Test("polishFallbackReason invariant: (reason != nil) == the real pipelineFellBackToRaw OR")
  func fallbackReasonInvariantMatchesOR() {
    // Lock the equivalence to the production formula
    // `filterFellBackToRaw || (validatedText == originalText)` so the new reason
    // can never drift from the boolean it disaggregates.
    let original = "the original text"
    let differing = "a different polished text"
    for filterFellBack in [false, true] {
      for validatedEqualsOriginal in [false, true] {
        let validated = validatedEqualsOriginal ? original : differing
        // postFilterOutput varied so both no_change and validator_discard arise.
        for postFilter in [original, differing] {
          let reason = LLMPolishStep.polishFallbackReason(
            filterFellBackToRaw: filterFellBack,
            postFilterOutput: postFilter,
            validatedText: validated,
            originalText: original)
          let expectedFellBack = filterFellBack || (validated == original)
          #expect((reason != nil) == expectedFellBack)
        }
      }
    }
  }

  @Test("ExecutionMetrics roundtrips polishFallbackReason through Codable")
  func executionMetricsRoundtripsFallbackReason() throws {
    let original = ExecutionMetrics(
      llmLatencySeconds: 0.5,
      polishFilterTripped: nil,
      polishFellBackToRaw: true,
      polishFallbackReason: "no_change")
    let decoded = try JSONDecoder().decode(
      ExecutionMetrics.self, from: try JSONEncoder().encode(original))
    #expect(decoded.polishFallbackReason == "no_change")
    #expect(decoded.polishFellBackToRaw == true)
  }

  @Test("ExecutionMetrics decodes pre-#1050 records (no polishFallbackReason) cleanly")
  func executionMetricsDecodesWithoutFallbackReason() throws {
    let oldShape = """
      {
        "coldStart": false,
        "streamingMode": false,
        "polishFellBackToRaw": true
      }
      """
    let metrics = try JSONDecoder().decode(
      ExecutionMetrics.self, from: oldShape.data(using: .utf8)!)
    #expect(metrics.polishFellBackToRaw == true)
    #expect(metrics.polishFallbackReason == nil)
  }

  #if DEBUG

    @Test("TelemetryService emits fallback_reason when passed")
    func telemetryServiceEmitsFallbackReason() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.llmPolishCompleted(
        provider: "appleIntelligence", model: "apple-intelligence",
        result: "success", latencySeconds: 0.4,
        filterTripped: nil, fellBackToRaw: true,
        fallbackReason: "no_change")

      let event = try await waiter.waitForEvent(named: "llm.polish_completed")
      #expect(event.stringProps["fallback_reason"] == "no_change")
      #expect(event.boolProps["fell_back_to_raw"] == true)
    }

    @Test("TelemetryService omits fallback_reason when nil (cloud / not a fallback)")
    func telemetryServiceOmitsFallbackReasonWhenNil() async throws {
      let waiter = TelemetryEventWaiter()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated { waiter.record(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.llmPolishCompleted(
        provider: "openai", model: "gpt-4o-mini",
        result: "success", latencySeconds: 1.0)

      let event = try await waiter.waitForEvent(named: "llm.polish_completed")
      #expect(event.stringProps["fallback_reason"] == nil)
    }

  #endif  // DEBUG

  // MARK: - 5. AFMPolishError shape + Sentry capture

  @Test("AFMPolishError preserves the underlying error")
  func afmPolishErrorPreservesUnderlying() {
    let wrapped = AFMPolishError(underlying: LLMError.emptyResponse)
    if let unwrapped = wrapped.underlying as? LLMError {
      #expect(unwrapped == LLMError.emptyResponse)
    } else {
      Issue.record("AFMPolishError did not preserve underlying error type")
    }
  }

  @Test("captureAFMPolishError records a generationFailed / polish event")
  func afmPolishErrorCaptureRecordsGenerationFailed() {
    struct Captured {
      let category: SentryBreadcrumb.ErrorCategory
      let stage: String
      let extra: [String: Any]
    }
    final class CaptureBox: @unchecked Sendable {
      private let lock = NSLock()
      private var _value: Captured?
      var value: Captured? {
        lock.lock()
        defer { lock.unlock() }
        return _value
      }
      func record(_ captured: Captured) {
        lock.lock()
        defer { lock.unlock() }
        _value = captured
      }
    }

    let box = CaptureBox()
    let prior = SentryBreadcrumb.captureErrorDelegate
    SentryBreadcrumb.captureErrorDelegate = { _, category, stage, extra in
      box.record(Captured(category: category, stage: stage, extra: extra ?? [:]))
    }
    defer { SentryBreadcrumb.captureErrorDelegate = prior }

    SentryBreadcrumb.captureAFMPolishError(LLMError.emptyResponse)

    let captured = box.value
    #expect(captured?.category == .generationFailed)
    #expect(captured?.stage == "polish")
    // Router fields were removed in #1072 — the event no longer carries them.
    #expect(captured?.extra["polish_mode"] == nil)
    #expect(captured?.extra["polish_router_basis"] == nil)
  }

  @Test(
    "captureAFMPolishError downgrades a cancellation to a breadcrumb",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1438",
      "AFM cancellation fired a full Sentry alert")
  )
  func afmPolishCancellationDowngradedToBreadcrumb() {
    final class SpyBox: @unchecked Sendable {
      private let lock = NSLock()
      private var _polishErrorCaptureCount = 0
      private var _breadcrumbs: [(stage: String, message: String)] = []
      var polishErrorCaptureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _polishErrorCaptureCount
      }
      var breadcrumbs: [(stage: String, message: String)] {
        lock.lock()
        defer { lock.unlock() }
        return _breadcrumbs
      }
      func recordPolishErrorCapture() {
        lock.lock()
        defer { lock.unlock() }
        _polishErrorCaptureCount += 1
      }
      func recordBreadcrumb(stage: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        _breadcrumbs.append((stage: stage, message: message))
      }
    }

    let spy = SpyBox()
    let priorErrorDelegate = SentryBreadcrumb.captureErrorDelegate
    let priorBreadcrumbDelegate = SentryBreadcrumb.breadcrumbDelegate
    SentryBreadcrumb.captureErrorDelegate = { _, category, stage, _ in
      guard category == .generationFailed, stage == "polish" else { return }
      spy.recordPolishErrorCapture()
    }
    SentryBreadcrumb.breadcrumbDelegate = { stage, message, _, _ in
      spy.recordBreadcrumb(stage: stage, message: message)
    }
    defer {
      SentryBreadcrumb.captureErrorDelegate = priorErrorDelegate
      SentryBreadcrumb.breadcrumbDelegate = priorBreadcrumbDelegate
    }

    SentryBreadcrumb.captureAFMPolishError(CancellationError())

    // Half 1: a cancelled polish is a clean unwind, never an alerting event.
    #expect(spy.polishErrorCaptureCount == 0)
    // Half 2: it still leaves a trail entry, matching the #979 downgrade precedent.
    // Both spies filter to this call's own signature: the delegates are process
    // globals, so an unrelated sibling emit must not redden this test.
    let cancellationCrumbs = spy.breadcrumbs.filter {
      $0.stage == "polish" && $0.message.contains("AFM polish cancelled")
    }
    #expect(cancellationCrumbs.count == 1)
  }

  // MARK: - 6. PolishMetadata Codable roundtrip

  @Test("PolishMetadata roundtrips through Codable")
  func polishMetadataCodableRoundtrip() throws {
    let original = PolishMetadata(
      filterTripped: "preamble_stripped",
      filterFellBackToRaw: false
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PolishMetadata.self, from: encoded)
    #expect(decoded == original)
  }
}
