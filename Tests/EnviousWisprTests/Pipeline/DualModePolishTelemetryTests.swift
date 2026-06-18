import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprPipeline

/// Tests for dual-mode polish telemetry plumbing (#429).
///
/// Coverage strategy: AppleIntelligenceConnector cannot be tested directly
/// (requires AFM macOS 26+). LLMPolishStep does not expose an injectable
/// polisher seam (it constructs the connector internally based on llmProvider),
/// so we cannot drive its catch path or `pipelineFellBackToRaw` computation
/// end-to-end through the public surface. Adding such a seam is out of scope
/// for #429 (telemetry-only). Instead this suite verifies:
///
///   1. PolishMetadata wraps cleanly into LLMResult.
///   2. ExecutionMetrics carries the four new fields and decodes old-shape
///      records (Codable backward-compat).
///   3. TelemetryService.llmPolishCompleted forwards new properties through
///      the testEventHook seam.
///   4. EnviousOutputFilter trips deterministically (fixed input/output pairs
///      from the documented imperative trigger list).
///   4b. The OR formula `pipelineFellBackToRaw = filter || validator` is
///       correct in isolation. The formula's *call site* in
///       LLMPolishStep.swift:248/312 is verified by Codex production inspection.
///   4c. The pipeline-side degradation `metadata == nil ? nil :
///       pipelineFellBackToRaw` is correct in isolation. Call sites at
///       Parakeet pipeline.swift:932 + KernelDictationDriver.swift:1050 are
///       verified by Codex production inspection.
///   5. AFMPolishError is a Sendable typed wrapper preserving underlying, and
///      SentryBreadcrumb captures post-router AFM failures with router fields
///      on the event instead of the global scope.
@MainActor
@Suite("Dual-mode polish telemetry — #429")
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
      routerMode: "natural",
      routerBasis: "scored",
      filterTripped: nil,
      filterFellBackToRaw: false
    )
    let result = LLMResult(polishedText: "hello", polishMetadata: meta)
    #expect(result.polishMetadata?.routerMode == "natural")
    #expect(result.polishMetadata?.routerBasis == "scored")
    #expect(result.polishMetadata?.filterTripped == nil)
    #expect(result.polishMetadata?.filterFellBackToRaw == false)
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
    #expect(metrics.polishRouterMode == nil)
    #expect(metrics.polishRouterBasis == nil)
    #expect(metrics.polishFilterTripped == nil)
    #expect(metrics.polishFellBackToRaw == nil)
  }

  @Test("ExecutionMetrics roundtrips new polish* fields through Codable")
  func executionMetricsRoundtripsPolishFields() throws {
    let original = ExecutionMetrics(
      llmLatencySeconds: 1.0,
      polishRouterMode: "technical",
      polishRouterBasis: "tier1",
      polishFilterTripped: "imperative_execution_guard",
      polishFellBackToRaw: true
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ExecutionMetrics.self, from: encoded)
    #expect(decoded.polishRouterMode == "technical")
    #expect(decoded.polishRouterBasis == "tier1")
    #expect(decoded.polishFilterTripped == "imperative_execution_guard")
    #expect(decoded.polishFellBackToRaw == true)
  }

  // MARK: - 3. TelemetryService surfaces new properties via testEventHook

  // testEventHook + CapturedTelemetryEvent are DEBUG-only — release builds
  // strip them from TelemetryService entirely. CI compiles tests with
  // `swift-test.sh -c release`, so these tests must be DEBUG-gated to
  // compile in both flavors. Coverage is preserved in dev test runs.
  #if DEBUG

    /// Sendable storage box for the testEventHook closure. The hook runs on the
    /// MainActor (TelemetryService is @MainActor) and `box.value` is only
    /// touched from the main thread, but Swift 6 strict concurrency requires
    /// the closure capture to be `Sendable`-safe.
    @MainActor
    final class EventBox {
      var value: CapturedTelemetryEvent?
    }

    @Test("TelemetryService emits all four new properties when fully populated")
    func telemetryServiceEmitsNewProperties() async {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in
          if event.name == "llm.polish_completed" { box.value = event }
        }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.llmPolishCompleted(
        provider: "appleIntelligence",
        model: "apple-intelligence",
        result: "success",
        latencySeconds: 0.873,
        routerMode: "technical",
        routerBasis: "tier1",
        filterTripped: "code_shape_guard",
        fellBackToRaw: true
      )

      // Allow the dispatched hook task to run.
      await Task.yield()
      try? await Task.sleep(nanoseconds: 5_000_000)

      let event = try? #require(box.value)
      #expect(event?.stringProps["provider"] == "appleIntelligence")
      #expect(event?.stringProps["router_mode"] == "technical")
      #expect(event?.stringProps["router_basis"] == "tier1")
      #expect(event?.stringProps["filter_tripped"] == "code_shape_guard")
      #expect(event?.boolProps["fell_back_to_raw"] == true)
    }

    @Test("TelemetryService omits polish properties for cloud providers (nil params)")
    func telemetryServiceOmitsForCloudProvider() async {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in
          if event.name == "llm.polish_completed" { box.value = event }
        }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.llmPolishCompleted(
        provider: "openai", model: "gpt-4o-mini",
        result: "success", latencySeconds: 1.2
      )

      await Task.yield()
      try? await Task.sleep(nanoseconds: 5_000_000)

      let event = try? #require(box.value)
      #expect(event?.stringProps["provider"] == "openai")
      #expect(event?.stringProps["router_mode"] == nil)
      #expect(event?.stringProps["router_basis"] == nil)
      #expect(event?.stringProps["filter_tripped"] == nil)
      #expect(event?.boolProps["fell_back_to_raw"] == nil)
    }

    @Test("TelemetryService emits fell_back_to_raw=false distinctly from absent")
    func telemetryServiceEmitsFalseFellBack() async {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in
          if event.name == "llm.polish_completed" { box.value = event }
        }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.llmPolishCompleted(
        provider: "appleIntelligence", model: "apple-intelligence",
        result: "success", latencySeconds: 0.5,
        routerMode: "natural", routerBasis: "scored",
        filterTripped: nil,
        fellBackToRaw: false
      )

      await Task.yield()
      try? await Task.sleep(nanoseconds: 5_000_000)

      let event = try? #require(box.value)
      #expect(event?.boolProps["fell_back_to_raw"] == false)
      // filter_tripped absent (passed nil) — schema cleanliness
      #expect(event?.stringProps["filter_tripped"] == nil)
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

  /// `LLMPolishStep.process()` computes `pipelineFellBackToRaw =
  /// filterFellBackToRaw || (validatedText == context.text)` on both the AFM and
  /// cloud paths. The OR is conceptually verified here; the production formula is
  /// now also locked against the new `#1050` reason helper by
  /// `fallbackReasonInvariantMatchesOR` below (section 7).
  @Test("pipelineFellBackToRaw is OR of filter outcome and validator outcome")
  func pipelineFellBackToRawIsOR() {
    func computeOR(filterFellBack: Bool, validatorFellBack: Bool) -> Bool {
      filterFellBack || validatorFellBack
    }
    #expect(computeOR(filterFellBack: false, validatorFellBack: false) == false)
    #expect(computeOR(filterFellBack: true, validatorFellBack: false) == true)
    #expect(computeOR(filterFellBack: false, validatorFellBack: true) == true)
    #expect(computeOR(filterFellBack: true, validatorFellBack: true) == true)
  }

  // MARK: - 4c. ExecutionMetrics nil-degrades-to-nil pattern (Pipelines §3.6)

  /// Pipelines build `polishFellBackToRaw: metadata == nil ? nil : pipelineFellBackToRaw`.
  /// When no AFM polish ran (cloud provider, or polish skipped), the field
  /// must be NIL — not `false` — so PostHog filtering on `fell_back_to_raw IS
  /// NOT NULL` correctly excludes non-AFM events. Production site:
  /// `KernelFinalizationWiring.updateTranscriptMetrics` (the `polishMetadata ==
  /// nil ? nil : …` gate, which `#1050` `polishFallbackReason` now mirrors).
  @Test("ExecutionMetrics.polishFellBackToRaw is nil when polishMetadata is absent")
  func executionMetricsFellBackIsNilWithoutMetadata() {
    let metadata: PolishMetadata? = nil
    let pipelineFellBackToRaw = false
    let polishFellBackToRaw: Bool? =
      metadata == nil ? nil : pipelineFellBackToRaw
    #expect(polishFellBackToRaw == nil)

    let metrics = ExecutionMetrics(
      polishRouterMode: metadata?.routerMode,
      polishRouterBasis: metadata?.routerBasis,
      polishFilterTripped: metadata?.filterTripped,
      polishFellBackToRaw: polishFellBackToRaw
    )
    #expect(metrics.polishRouterMode == nil)
    #expect(metrics.polishRouterBasis == nil)
    #expect(metrics.polishFilterTripped == nil)
    #expect(metrics.polishFellBackToRaw == nil)
  }

  @Test("ExecutionMetrics.polishFellBackToRaw is false when AFM ran but pipeline did not fall back")
  func executionMetricsFellBackIsFalseOnSuccessfulAFM() {
    let metadata = PolishMetadata(
      routerMode: "natural", routerBasis: "scored",
      filterTripped: nil, filterFellBackToRaw: false
    )
    let pipelineFellBackToRaw = false  // validator did not trigger either
    let polishFellBackToRaw: Bool? =
      Optional<PolishMetadata>.some(metadata) == nil ? nil : pipelineFellBackToRaw

    let metrics = ExecutionMetrics(
      polishRouterMode: metadata.routerMode,
      polishRouterBasis: metadata.routerBasis,
      polishFilterTripped: metadata.filterTripped,
      polishFellBackToRaw: polishFellBackToRaw
    )
    #expect(metrics.polishRouterMode == "natural")
    #expect(metrics.polishFellBackToRaw == false)
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
      polishRouterMode: "natural",
      polishRouterBasis: "scored",
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
    func telemetryServiceEmitsFallbackReason() async {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in
          if event.name == "llm.polish_completed" { box.value = event }
        }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.llmPolishCompleted(
        provider: "appleIntelligence", model: "apple-intelligence",
        result: "success", latencySeconds: 0.4,
        routerMode: "natural", routerBasis: "scored",
        filterTripped: nil, fellBackToRaw: true,
        fallbackReason: "no_change")

      await Task.yield()
      try? await Task.sleep(nanoseconds: 5_000_000)

      let event = try? #require(box.value)
      #expect(event?.stringProps["fallback_reason"] == "no_change")
      #expect(event?.boolProps["fell_back_to_raw"] == true)
    }

    @Test("TelemetryService omits fallback_reason when nil (cloud / not a fallback)")
    func telemetryServiceOmitsFallbackReasonWhenNil() async {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        Task { @MainActor in
          if event.name == "llm.polish_completed" { box.value = event }
        }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.llmPolishCompleted(
        provider: "openai", model: "gpt-4o-mini",
        result: "success", latencySeconds: 1.0)

      await Task.yield()
      try? await Task.sleep(nanoseconds: 5_000_000)

      let event = try? #require(box.value)
      #expect(event?.stringProps["fallback_reason"] == nil)
    }

  #endif  // DEBUG

  // MARK: - 5. AFMPolishError shape

  @Test("AFMPolishError preserves underlying error and router metadata")
  func afmPolishErrorPreservesUnderlying() {
    let underlying = LLMError.emptyResponse
    let wrapped = AFMPolishError(
      underlying: underlying,
      routerMode: "technical",
      routerBasis: "tier1"
    )
    #expect(wrapped.routerMode == "technical")
    #expect(wrapped.routerBasis == "tier1")
    if let unwrapped = wrapped.underlying as? LLMError {
      #expect(unwrapped == LLMError.emptyResponse)
    } else {
      Issue.record("AFMPolishError did not preserve underlying error type")
    }
  }

  @Test("AFM polish error capture includes router metadata on the event")
  func afmPolishErrorCaptureIncludesRouterMetadata() {
    struct Captured {
      let category: SentryBreadcrumb.ErrorCategory
      let stage: String
      let extra: [String: Any]
      let tags: [String: String]
    }
    final class CaptureBox: @unchecked Sendable {
      private let lock = NSLock()
      private var _value: Captured?
      private var _tags: [String: String] = [:]

      var value: Captured? {
        lock.lock()
        defer { lock.unlock() }
        return _value
      }

      func recordTags(_ tags: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        _tags = tags
      }

      func record(_ captured: Captured) {
        lock.lock()
        defer { lock.unlock() }
        _value = Captured(
          category: captured.category,
          stage: captured.stage,
          extra: captured.extra,
          tags: _tags
        )
      }
    }

    let box = CaptureBox()
    let prior = SentryBreadcrumb.captureErrorDelegate
    let priorTags = SentryBreadcrumb.captureErrorTagsDelegate
    SentryBreadcrumb.captureErrorTagsDelegate = { tags in
      box.recordTags(tags)
    }
    SentryBreadcrumb.captureErrorDelegate = { _, category, stage, extra in
      box.record(Captured(category: category, stage: stage, extra: extra ?? [:], tags: [:]))
    }
    defer { SentryBreadcrumb.captureErrorDelegate = prior }
    defer { SentryBreadcrumb.captureErrorTagsDelegate = priorTags }

    SentryBreadcrumb.captureAFMPolishError(
      LLMError.emptyResponse,
      routerMode: "technical",
      routerBasis: "tier1"
    )

    let captured = box.value
    #expect(captured?.category == .generationFailed)
    #expect(captured?.stage == "polish")
    #expect(captured?.extra["polish_mode"] as? String == "technical")
    #expect(captured?.extra["polish_router_basis"] as? String == "tier1")
    #expect(captured?.tags["pipeline.stage"] == "polish")
    #expect(captured?.tags["error.category"] == "generation_failed")
    #expect(captured?.tags["polish_mode"] == "technical")
    #expect(captured?.tags["polish_router_basis"] == "tier1")
  }

  // MARK: - 6. PolishMetadata Codable roundtrip

  @Test("PolishMetadata roundtrips through Codable")
  func polishMetadataCodableRoundtrip() throws {
    let original = PolishMetadata(
      routerMode: "natural",
      routerBasis: "scored",
      filterTripped: "preamble_stripped",
      filterFellBackToRaw: false
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PolishMetadata.self, from: encoded)
    #expect(decoded == original)
  }
}
