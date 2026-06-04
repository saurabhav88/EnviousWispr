import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - KernelFinalizationWiringTests (epic #827, PR-4 §11.4)
//
// Unit coverage for `KernelFinalizationWiring` — the processText / store /
// deliver closures and the wedge-tuning constants. `save` / `deliverPaste`
// are fake closures so the suite touches neither disk nor the AX paste APIs.

@MainActor
@Suite struct KernelFinalizationWiringTests {

  // MARK: Wedge tuning (PR-4 §3.6)

  @Test("wedge tuning is precedent-derived: 10 ticks x 100ms = a 1.0s window")
  func wedgeTuning() {
    #expect(KernelFinalizationWiring.wedgeStallTicks == 10)
    #expect(KernelFinalizationWiring.tickDurationSeconds == 0.1)
    // 1.0 s window >= LoadProgressWatcher's 0.8 s silence floor.
    let windowSeconds =
      Double(KernelFinalizationWiring.wedgeStallTicks)
      * KernelFinalizationWiring.tickDurationSeconds
    #expect(windowSeconds >= 0.8)
  }

  @Test(
    "currentTick advances by the number of whole logical ticks elapsed",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/900",
      "logical tick rate was unverified (tautology)"
    )
  )
  func currentTickAdvancesWithClock() async {
    // Inject a manual clock so logical time advances by hand — no Task.sleep
    // cadence (`tests-no-real-time-scheduling-precision`). The old test asserted
    // `first == currentTick() || currentTick() >= first`, true for any monotonic
    // or even frozen clock, so a frozen clock or wrong tick divisor passed.
    let clock = ManualClock()
    let wiring = makeWiring(currentTime: { clock.now })
    let first = wiring.currentTick()  // floor(0 / 0.1) == 0

    // Advance 3.5 ticks: landing mid-window means floating-point error in
    // `UInt64(now / tickDurationSeconds)` cannot straddle a tick boundary, so
    // exactly 3 whole ticks have elapsed. (Advancing a clean 3.0 ticks would
    // rely on the lucky rounding of `0.1 * 3 / 0.1`; 3.5 is boundary-safe.)
    clock.advance(by: KernelFinalizationWiring.tickDurationSeconds * 3.5)
    #expect(wiring.currentTick() == first + 3)

    await wiring.sleepTicks(0)  // a zero-tick sleep returns promptly (liveness)
  }

  // MARK: processText

  @Test("processText runs the limb chain and writes the polish side-channel")
  func processTextWritesSideChannel() async throws {
    let outcome = KernelFinalizationOutcome()
    let wiring = makeWiring(outcome: outcome)
    let result = try await wiring.processText("hello there") {}
    #expect(!result.isEmpty)
    #expect(outcome.rawText != nil, "the raw ASR text is recorded for the store closure")
  }

  @Test("processText wires onPolishStarted into LLMPolishStep.onWillProcess")
  func processTextWiresPolishSignal() async throws {
    let steps = makeSteps()
    let wiring = makeWiring(steps: steps)
    let signal = SignalFlag()
    _ = try await wiring.processText("hello") { signal.fired = true }
    // The closure is now installed on the polish step — the limb emits, the
    // kernel observes (D18 closed, PR-4 §3.8).
    steps.llmPolish.onWillProcess?()
    #expect(signal.fired)
  }

  // MARK: ITN floor (#145)

  @Test("ITN runs in the live chain: spoken numbers are formatted (floor on)")
  func itnFormatsInChain() async throws {
    let outcome = KernelFinalizationOutcome()
    let wiring = makeWiring(outcome: outcome)
    // Polish is OFF in this harness (no API key) → the chain's final text is
    // the post-ITN text = the raw-fallback floor.
    let result = try await wiring.processText("the code is two zero three") {}
    #expect(result == "the code is 203")
    #expect(outcome.itnRan)
    #expect(outcome.itnChanged)
    #expect(outcome.itnSkipReason == nil)
  }

  @Test("ITN floor is delivered end-to-end: metrics flag the polish-off floor")
  func itnFloorDeliveredMetrics() async throws {
    let outcome = KernelFinalizationOutcome()
    let saved = SavedTranscriptBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)
    let wiring = makeWiring(outcome: outcome, context: context, save: { saved.transcript = $0 })

    let floored = try await wiring.processText(
      "call me at two zero three nine five four eight eight seven nine"
    ) {}
    try await wiring.store(floored)
    _ = await wiring.deliver(floored)

    let metrics = try #require(outcome.transcript?.metrics)
    #expect(metrics.itnRan == true)
    #expect(metrics.itnChanged == true)
    #expect(metrics.itnFloorDelivered == true, "polish off + ITN changed => the user got the floor")
    #expect(metrics.itnSkipReason == nil)
    #expect((metrics.itnLenBefore ?? 0) > 0)
  }

  @Test("plain prose is a no-op: ITN ran, changed nothing, floor not delivered")
  func itnNoOpPassthrough() async throws {
    let outcome = KernelFinalizationOutcome()
    let saved = SavedTranscriptBox()
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)
    let wiring = makeWiring(outcome: outcome, context: context, save: { saved.transcript = $0 })

    let result = try await wiring.processText("hello there friend") {}
    try await wiring.store(result)
    _ = await wiring.deliver(result)

    #expect(result == "hello there friend")
    let metrics = try #require(outcome.transcript?.metrics)
    #expect(metrics.itnRan == true)
    #expect(metrics.itnChanged == false)
    #expect(metrics.itnFloorDelivered == false)
  }

  @Test("chain order: filler removal runs BEFORE ITN")
  func itnRunsAfterFillerRemoval() async throws {
    let steps = makeSteps()
    steps.fillerRemoval.fillerRemovalEnabled = true
    let wiring = makeWiring(steps: steps)
    // "um" is stripped by filler removal first; ITN then formats the cleaned
    // number. If ITN ran before filler removal the spacing would differ.
    let result = try await wiring.processText("um the code is two zero three") {}
    #expect(result == "the code is 203")
  }

  @Test("per-session gate wire reads the engine LID capability, not an identity literal")
  func itnBackendCapabilityWired() async throws {
    let steps = makeSteps()
    let wiring = makeWiring(steps: steps)
    _ = try await wiring.processText("hello") {}
    // The Parakeet-class adapter does not support LID → the step's gate hint is
    // wired to false (run on English-or-unknown), sourced from
    // `adapter.capabilities.supportsLanguageDetection`.
    #expect(steps.inverseTextNormalization.backendSupportsLID == false)
  }

  @Test(
    "itn_floor_delivered is true whenever polish did not deliver a distinct result",
    arguments: [
      // (itnChanged, polished, raw, fellBack, expected)
      (false, String?.none, String?.some("203"), false, false),  // ITN didn't change → never
      (true, String?.none, String?.some("203"), false, true),  // polish disabled → floor
      (true, String?.some("203"), String?.some("203"), true, true),  // rejected → floor
      (true, String?.some("203"), String?.some("203"), false, true),  // short-circuit (==) → floor
      (true, String?.some("Two oh three"), String?.some("203"), false, false),  // distinct polish → not floor
    ])
  func floorDeliveredLogic(
    itnChanged: Bool, polished: String?, raw: String?, fellBack: Bool, expected: Bool
  ) {
    #expect(
      KernelFinalizationWiring.itnFloorDelivered(
        itnChanged: itnChanged, polishedText: polished, rawText: raw,
        pipelineFellBackToRaw: fellBack) == expected)
  }

  // MARK: store

  @Test("store builds the Transcript from the side-channel and persists it")
  func storeBuildsAndSaves() async throws {
    let outcome = KernelFinalizationOutcome()
    outcome.rawText = "raw asr text"
    outcome.polishedText = "polished text"
    outcome.llmProvider = "openai"
    outcome.llmModel = "gpt-4o-mini"
    let saved = SavedTranscriptBox()
    let wiring = makeWiring(outcome: outcome, save: { saved.transcript = $0 })

    try await wiring.store("polished text")

    #expect(saved.transcript?.text == "raw asr text")
    #expect(saved.transcript?.polishedText == "polished text")
    #expect(saved.transcript?.backendType == .parakeet)
    #expect(saved.transcript?.llmProvider == "openai")
    #expect(outcome.transcript?.text == "raw asr text", "the driver reads the transcript here")
  }

  @Test("store rethrows a storage failure so the kernel routes failed(storageFailed)")
  func storeRethrows() async {
    let wiring = makeWiring(save: { _ in throw WiringTestError.storage })
    await #expect(throws: WiringTestError.self) {
      try await wiring.store("text")
    }
  }

  // MARK: deliver

  @Test("deliver pastes when auto-paste is on and the cascade delivered")
  func deliverPastes() async {
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)
    let wiring = makeWiring(context: context, deliverPaste: { _ in Self.deliveredResult })
    let outcome = await wiring.deliver("hello")
    #expect(outcome == .pasted)
  }

  @Test("deliver reports clipboardOnly when the cascade fell back")
  func deliverClipboardFallback() async {
    let context = KernelSessionContext()
    context.config = .testDefault(autoPasteToActiveApp: true)
    let wiring = makeWiring(context: context, deliverPaste: { _ in Self.clipboardResult })
    let outcome = await wiring.deliver("hello")
    #expect(outcome == .clipboardOnly)
  }

  @Test("deliver reports clipboardOnly for a copy-to-clipboard-only session")
  func deliverCopyOnly() async {
    let context = KernelSessionContext()
    context.config = .testDefault(autoCopyToClipboard: true, autoPasteToActiveApp: false)
    let wiring = makeWiring(context: context, deliverPaste: { _ in Self.deliveredResult })
    let outcome = await wiring.deliver("hello")
    #expect(outcome == .clipboardOnly, "no auto-paste => never .pasted")
  }

  // MARK: Helpers

  private static let deliveredResult = PasteDeliveryResult(
    tier: .cgEvent, durationMs: 5,
    outcome: .delivered(tier: .cgEvent, durationMs: 5))

  private static let clipboardResult = PasteDeliveryResult(
    tier: .clipboardOnly, durationMs: 1,
    outcome: .clipboardOnlyAccessibilityDenied(targetBundleID: nil))

  private func makeSteps() -> LimbSteps {
    LimbSteps(
      wordCorrection: WordCorrectionStep(),
      fillerRemoval: FillerRemovalStep(),
      emojiFormatter: EmojiFormatterStep(),
      inverseTextNormalization: InverseTextNormalizationStep(),
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()))
  }

  private func makeWiring(
    outcome: KernelFinalizationOutcome = KernelFinalizationOutcome(),
    context: KernelSessionContext = KernelSessionContext(),
    steps: LimbSteps? = nil,
    save: @escaping @MainActor (Transcript) throws -> Void = { _ in },
    deliverPaste: @escaping @MainActor (PasteDeliveryRequest) async -> PasteDeliveryResult = {
      _ in Self.deliveredResult
    },
    currentTime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) -> KernelFinalizationWiring {
    KernelFinalizationWiring(
      outcome: outcome,
      context: context,
      adapter: ParakeetEngineAdapter(asrManager: StubParakeetASRManager()),
      steps: steps ?? makeSteps(),
      textProcessingRunner: TextProcessingRunner(),
      save: save,
      deliverPaste: deliverPaste,
      pasteCompletionRegistry: nil,
      currentTime: currentTime)
  }
}

/// Hand-advanced logical clock for the tick-rate test. Local `@MainActor` copy:
/// the `ManualClock` in `LoadProgressWatcherTests` is `private` to that suite and
/// cannot be reused. Satisfies the `@MainActor () -> TimeInterval` clock seam.
@MainActor
private final class ManualClock {
  private(set) var now: TimeInterval = 0
  func advance(by seconds: TimeInterval) { now += seconds }
}

private enum WiringTestError: Error { case storage }

@MainActor
private final class SignalFlag {
  var fired = false
}

@MainActor
private final class SavedTranscriptBox {
  var transcript: Transcript?
}
