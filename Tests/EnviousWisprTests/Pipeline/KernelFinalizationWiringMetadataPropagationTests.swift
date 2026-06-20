import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - KernelFinalizationWiringMetadataPropagationTests (epic #827, PR-5 Rung 2A)
//
// Sentinel coverage for the protocol-typed `adapter.lastResult` read at
// `KernelFinalizationWiring.swift:156-158`. Drives the production `store`
// closure with a `FakeEngine` whose engine identity is `.whisperKit` and
// whose `lastResult` is seeded with deterministic metadata. A future
// refactor that re-narrows the `adapter:` parameter back to a concrete type
// fails to compile here (FakeEngine is not `ParakeetEngineAdapter`); a
// silent regression that bypassed the protocol getter would corrupt the
// metadata reads asserted below.

@MainActor
@Suite struct KernelFinalizationWiringMetadataPropagationTests {

  @Test("store closure reads ASR metadata + backend through the protocol existential")
  func metadataReadsThroughProtocol() async throws {
    let engine = FakeEngine(behavior: .batchSuccess(text: "hi"), clock: FakeClock())
    engine.engineIdentity = ASREngineIdentity(backendType: .whisperKit)
    engine.lastResult = ASRResult(
      text: "hi", language: "es", duration: 1.5, processingTime: 0.2,
      backendType: .whisperKit)

    let outcome = KernelFinalizationOutcome()
    outcome.rawText = "hi"

    let saved = SavedTranscriptBox()
    let wiring = KernelFinalizationWiring(
      outcome: outcome,
      context: KernelSessionContext(),
      adapter: engine,
      steps: LimbSteps(
        wordCorrection: WordCorrectionStep(),
        fillerRemoval: FillerRemovalStep(),
        emojiFormatter: EmojiFormatterStep(),
        inverseTextNormalization: InverseTextNormalizationStep(),
        llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
        emojiRestore: EmojiRestoreStep()),
      textProcessingRunner: TextProcessingRunner(),
      save: { saved.transcript = $0 },
      deliverPaste: { _ in
        PasteDeliveryResult(
          tier: .cgEvent, durationMs: 1,
          outcome: .delivered(tier: .cgEvent, durationMs: 1))
      },
      pasteCompletionRegistry: nil)

    try await wiring.store("hi")

    let transcript = try #require(saved.transcript)
    #expect(transcript.language == "es")
    #expect(transcript.duration == 1.5)
    #expect(transcript.processingTime == 0.2)
    #expect(transcript.backendType == .whisperKit)
    #expect(outcome.transcript?.language == "es")
  }
}

@MainActor
private final class SavedTranscriptBox {
  var transcript: Transcript?
}
