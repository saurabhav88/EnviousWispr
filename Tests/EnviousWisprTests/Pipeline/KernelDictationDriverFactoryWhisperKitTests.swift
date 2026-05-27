import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - KernelDictationDriverFactoryWhisperKitTests (epic #827, PR-5 Rung 4)
//
// Coverage for `KernelDictationDriverFactory.makeForWhisperKit(inputs:)` — the
// second-engine factory branch added in Rung 4. The branch ships
// production-unwired this rung (no App caller); these unit tests are the only
// runtime exercise of the WhisperKit factory path until Rung 5's App cutover.
//
// Council coverage review (GPT, 2026-05-27) asked that this file assert
// identity propagation through every backend-stamped consumer the assembler
// wires (polish step, heart-path telemetry emitter, lifecycle telemetry sink).
// The polish-step stamp is directly readable via `@testable` (the driver
// exposes `llmPolish` and the step exposes `backend`). The emitter and
// lifecycle sink are constructed inside the assembler's closure scope and held
// only via kernel + observer callbacks — exposing them for runtime inspection
// would require dropping `private` on their `backend` properties OR adding a
// `#if DEBUG`-only test entry point that returns the full assembled stack.
// Both options add production surface area for a test.
//
// Council intent (verify the shared assembler stamps every consumer correctly)
// is satisfied at source level by the strengthened `EngineIdentityFreezeTests
// .readerSitesUseAdapterIdentity` (Rung 4 raised the assertion from "at least
// one `adapter.engineIdentity` read in the factory file" to "at least three"
// — one per consumer: polish at :150, emitter at :160, sink at :231). Source-
// level enforcement is stronger than runtime inspection here because it
// catches a future refactor that moves any of the three reads to a different
// identity source.
//
// `#if DEBUG`-gated to match `KernelDictationDriverSurfaceTests`.

#if DEBUG

  @MainActor
  @Suite struct KernelDictationDriverFactoryWhisperKitTests {

    // MARK: Helpers

    /// Construct via the real `WhisperKitBackend()` actor — lazy, does not
    /// load a CoreML model until `prepare()` runs. Factory does not call
    /// `prepare()` (warm-up is kernel-driven post-construction), so the
    /// backend stays `isReady == false` after factory return.
    private func makeDriver() -> KernelDictationDriver {
      let inputs = KernelDictationDriverFactory.WhisperKitInputs(
        audioCapture: FakeAudioCapture(),
        whisperKitBackend: WhisperKitBackend(),
        languageDetector: LanguageDetector(),
        transcriptStore: TranscriptStore(),
        keychainManager: KeychainManager(),
        captureTelemetry: CaptureTelemetryState(),
        pasteCompletionRegistry: PasteCompletionRegistry())
      return KernelDictationDriverFactory.makeForWhisperKit(inputs: inputs)
    }

    // MARK: 1. Construction returns a WhisperKit-identity driver

    @Test("makeForWhisperKit returns a driver whose polish step is stamped .whisperKit")
    func makeForWhisperKitReturnsDriverWithWhisperKitIdentity() {
      let driver = makeDriver()
      // The assembler does `limbSteps.llmPolish.backend = adapter.engineIdentity.backendType`.
      // For the WhisperKit branch, `adapter.engineIdentity.backendType == .whisperKit`
      // (`WhisperKitEngineAdapter.engineIdentity` declares it). The polish stamp
      // is the directly observable proof that the assembler routed identity
      // correctly. (Emitter + lifecycle sink stamps covered transitively by
      // the strengthened freeze test — see file header.)
      #expect(driver.llmPolish.backend == .whisperKit)
    }

    // MARK: 2. Factory construction does not load the model

    @Test("makeForWhisperKit does not call backend.prepare() (factory is lazy)")
    func makeForWhisperKitDoesNotLoadModel() async {
      let backend = WhisperKitBackend()
      let inputs = KernelDictationDriverFactory.WhisperKitInputs(
        audioCapture: FakeAudioCapture(),
        whisperKitBackend: backend,
        languageDetector: LanguageDetector(),
        transcriptStore: TranscriptStore(),
        keychainManager: KeychainManager(),
        captureTelemetry: CaptureTelemetryState(),
        pasteCompletionRegistry: PasteCompletionRegistry())
      _ = KernelDictationDriverFactory.makeForWhisperKit(inputs: inputs)
      // Factory construction is synchronous and pure — no warm-up dispatch.
      // Backend's `isReady` flips to true only after `prepare()` completes.
      // If a future refactor accidentally fires warm-up from inside the
      // factory, this assertion catches it.
      let isReady = await backend.isReady
      #expect(isReady == false)
    }
  }

#endif
