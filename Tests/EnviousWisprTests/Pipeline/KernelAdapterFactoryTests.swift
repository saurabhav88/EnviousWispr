import AVFoundation
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprPipeline

// MARK: - KernelAdapterFactoryTests (epic #827, PR-6)
//
// Identity unit tests for `KernelAdapterFactory`'s two make functions. The
// freeze tests (`EngineIdentityFreezeTests` Test A / Test B) lock concrete
// adapter construction to this factory at source level; these runtime tests
// close the §7 gap the `any ASREngineAdapter` return type leaves open: the
// compiler does not prove `makeWhisperKitAdapter` returns a `.whisperKit`
// identity adapter, so assert each make function yields the right identity.
//
// There is no shared `FakeASRManager` (the ASR-manager fakes are `private` to
// `SetupCoordinatorTests` / `DictationSessionConfigFactoryTests`), so this file
// defines its own minimal local `ASRManagerInterface` conformer (Codex r2).

@MainActor
@Suite struct KernelAdapterFactoryTests {

  @Test("makeParakeetAdapter returns a .parakeet-identity adapter")
  func makeParakeetAdapterHasParakeetIdentity() {
    let adapter = KernelAdapterFactory.makeParakeetAdapter(
      asrManager: MinimalASRManager(), parakeetUpgrade: .legacyForTesting())
    #expect(adapter.engineIdentity.backendType == .parakeet)
  }

  @Test("makeWhisperKitAdapter returns a .whisperKit-identity adapter")
  func makeWhisperKitAdapterHasWhisperKitIdentity() {
    // `WhisperKitBackend()` is the lazy actor (no CoreML load until prepare()),
    // matching `KernelDictationDriverFactoryWhisperKitTests`.
    let adapter = KernelAdapterFactory.makeWhisperKitAdapter(
      backend: WhisperKitBackend(admittedModelFolder: { nil }),
      languageDetector: LanguageDetector(),
      audioCaptureSessionIDSource: { 0 },
      engineMutationScope: .alwaysAllowedForTesting,
      vendorDecodeOccupancy: VendorDecodeOccupancy(),
      deliveredModelIdentity: nil)
    #expect(adapter.engineIdentity.backendType == .whisperKit)
  }
}

/// Minimal local `ASRManagerInterface` conformer. The factory only needs an
/// object satisfying the protocol; `ParakeetEngineAdapter`'s identity is
/// `.parakeet` regardless of manager behavior, so every member is an inert stub.
@MainActor
private final class MinimalASRManager: ASRManagerInterface {
  var activeBackendType: ASRBackendType = .parakeet
  var isModelLoaded = false
  let vendorDecodeOccupancy = VendorDecodeOccupancy()
  var onVendorDecodeChunkScheduled: (@MainActor @Sendable () -> Void)?
  var onTranscriptionProgress: (@MainActor @Sendable (Double) -> Void)?
  var isStreaming = false
  var downloadProgress: Double = 0
  var downloadPhase = ""
  var downloadDetail = ""
  var loadProgressTickReporter: (@MainActor @Sendable (Date?, String) -> Void)?
  var onServiceInterrupted: (() -> Void)?

  func loadModel() async throws {}
  func unloadModel() async {}
  func setInitialBackendType(_ type: ASRBackendType) {}
  func switchBackend(to type: ASRBackendType) async {}
  var activeBackendSupportsStreaming: Bool { get async { false } }
  func transcribe(
    audioSamples: [Float], options: TranscriptionOptions,
    onInferenceEntered: ASRInferenceEntryObserver? = nil
  ) async throws -> ASRResult {
    ASRResult(text: "", language: "en", duration: 0, processingTime: 0, backendType: .parakeet)
  }
  func startStreaming(
    options: TranscriptionOptions, attemptID: UUID,
    onWindowInferenceEntered: ASRInferenceEntryObserver? = nil
  ) async throws {}
  func feedAudio(_ buffer: AVAudioPCMBuffer) async throws {}
  func finalizeStreaming() async throws -> ASRResult {
    ASRResult(text: "", language: "en", duration: 0, processingTime: 0, backendType: .parakeet)
  }
  func cancelStreaming() async {}
  func noteTranscriptionComplete(policy: ModelUnloadPolicy) {}
  func cancelIdleTimer() {}
  func cancelInFlightLoad() {}
}
