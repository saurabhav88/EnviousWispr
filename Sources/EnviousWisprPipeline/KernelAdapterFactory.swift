import EnviousWisprASR
import EnviousWisprCore
import Foundation

/// The single concrete `ASREngineAdapter` construction owner (epic #827, PR-6).
///
/// Before PR-6 the driver-assembly factory (`KernelDictationDriverFactory`)
/// constructed both concrete adapters inline, so it named `ParakeetEngineAdapter`
/// and `WhisperEngineAdapter` directly and engine construction was entangled
/// with driver assembly. PR-6 moves the two construction expressions here so
/// there is one home that knows how to build each engine's adapter, and the
/// driver-assembly factory names no concrete adapter type in code.
///
/// This is a construction OWNER, not a runtime `backendType -> adapter` dispatch
/// map: each make function takes exactly the dependencies its engine needs (the
/// type-system-enforced per-engine surface chosen in PR-5 Rung 4, which
/// deliberately rejected a single optional all-engines dependency bundle).
/// Backend selection stays in the existing typed driver/App wiring; this type
/// only constructs.
///
/// Hot-swap (epic goal #4): adding an engine is "write the `ASREngineAdapter`
/// conformer plus a make function here," touching zero lines of
/// `RecordingSessionKernel`. The kernel already consumes an opaque
/// `any ASREngineAdapter`; the PR-2 fake engine is the standing kernel-isolation
/// proof. `EngineIdentityFreezeTests` Test A locks construction to this file.
@MainActor
package enum KernelAdapterFactory {

  /// The single Parakeet adapter construction site in `Sources/`.
  /// `parakeetUpgrade` (#3546): required; the Parakeet selection-policy owner,
  /// which holds the delivery handle (#1348 Phase 2) and the request provider
  /// `ASRManager` reads.
  /// `batchDecodeFaultController` (#1707 Phase 2): DEBUG fault-injection
  /// oracle, defaulted `nil` so every existing test call site is unaffected.
  package static func makeParakeetAdapter(
    asrManager: any ASRManagerInterface,
    parakeetUpgrade: ParakeetUpgradeCoordinator,
    batchDecodeFaultController: BatchDecodeFaultController? = nil,
    isSharedEngineHeldByOtherWorkload: @escaping @MainActor () -> Bool
  ) -> any ASREngineAdapter {
    ParakeetEngineAdapter(
      asrManager: asrManager, parakeetUpgrade: parakeetUpgrade,
      batchDecodeFaultController: batchDecodeFaultController,
      isSharedEngineHeldByOtherWorkload: isSharedEngineHeldByOtherWorkload)
  }

  /// #3735: the production Whisper adapter, over transcribe.cpp. It starts the adapter's
  /// memory-pressure binding (§3.2a) here, at construction. The production backend is built
  /// with `loadsAfterPressureBinding`, so every load, from any caller, waits for this binding:
  /// no model is ever resident on it without the EngineMutationScope-authorized pressure
  /// unload.
  package static func makeWhisperAdapter<Driver: WhisperExecutorDriving>(
    backend: TranscribeCppWhisperBackend<Driver>,
    languageDetector: LanguageDetector,
    audioCaptureSessionIDSource: @escaping @MainActor () -> UInt64,
    engineMutationScope: EngineMutationScope,
    vendorDecodeOccupancy: VendorDecodeOccupancy,
    deliveredModelIdentity: ASRModelIdentity?,
    batchDecodeFaultController: BatchDecodeFaultController? = nil
  ) -> any ASREngineAdapter {
    let adapter = WhisperEngineAdapter(
      backend: backend,
      engineMutationScope: engineMutationScope,
      languageDetector: languageDetector,
      audioCaptureSessionIDSource: audioCaptureSessionIDSource,
      vendorDecodeOccupancy: vendorDecodeOccupancy,
      batchDecodeFaultController: batchDecodeFaultController,
      deliveredModelIdentity: deliveredModelIdentity)
    adapter.startMemoryPressureBinding(to: backend)
    return adapter
  }
}
