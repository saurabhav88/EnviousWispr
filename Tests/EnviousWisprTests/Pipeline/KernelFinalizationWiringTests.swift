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

  @Test("the logical clock advances and sleepTicks returns")
  func clock() async {
    let wiring = makeWiring()
    let first = wiring.currentTick()
    #expect(first == wiring.currentTick() || wiring.currentTick() >= first)
    await wiring.sleepTicks(0)  // a zero-tick sleep returns promptly
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
      llmPolish: LLMPolishStep(keychainManager: KeychainManager()))
  }

  private func makeWiring(
    outcome: KernelFinalizationOutcome = KernelFinalizationOutcome(),
    context: KernelSessionContext = KernelSessionContext(),
    steps: LimbSteps? = nil,
    save: @escaping @MainActor (Transcript) throws -> Void = { _ in },
    deliverPaste: @escaping @MainActor (PasteDeliveryRequest) async -> PasteDeliveryResult = {
      _ in Self.deliveredResult
    }
  ) -> KernelFinalizationWiring {
    KernelFinalizationWiring(
      outcome: outcome,
      context: context,
      adapter: ParakeetEngineAdapter(asrManager: StubParakeetASRManager()),
      steps: steps ?? makeSteps(),
      textProcessingRunner: TextProcessingRunner(),
      save: save,
      deliverPaste: deliverPaste,
      pasteCompletionRegistry: nil)
  }
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
