import EnviousWisprASR
import Foundation

/// The single concrete `ASREngineAdapter` construction owner (epic #827, PR-6).
///
/// Before PR-6 the driver-assembly factory (`KernelDictationDriverFactory`)
/// constructed both concrete adapters inline, so it named `ParakeetEngineAdapter`
/// and `WhisperKitEngineAdapter` directly and engine construction was entangled
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
  /// `delivery` (#1348 Phase 2): nil = legacy in-service download path.
  /// `batchDecodeFaultController` (#1707 Phase 2): DEBUG fault-injection
  /// oracle, defaulted `nil` so every existing test call site is unaffected.
  package static func makeParakeetAdapter(
    asrManager: any ASRManagerInterface,
    delivery: ParakeetDeliveryHandle? = nil,
    batchDecodeFaultController: BatchDecodeFaultController? = nil
  ) -> any ASREngineAdapter {
    ParakeetEngineAdapter(
      asrManager: asrManager, delivery: delivery,
      batchDecodeFaultController: batchDecodeFaultController)
  }

  /// The single WhisperKit adapter construction site in `Sources/`.
  /// `audioCaptureSessionIDSource` mirrors the adapter's own parameter (PR-5
  /// Rung 4.5) so the adapter can snapshot the capture session id at
  /// `beginSession` for race-safe delayed LID perf signposts.
  /// `batchDecodeFaultController` (#1707 Phase 2): DEBUG fault-injection
  /// oracle, defaulted `nil` so every existing test call site is unaffected.
  package static func makeWhisperKitAdapter(
    backend: any WhisperKitBackendDriving,
    languageDetector: LanguageDetector,
    audioCaptureSessionIDSource: @escaping @MainActor () -> UInt64,
    batchDecodeFaultController: BatchDecodeFaultController? = nil
  ) -> any ASREngineAdapter {
    WhisperKitEngineAdapter(
      backend: backend,
      languageDetector: languageDetector,
      audioCaptureSessionIDSource: audioCaptureSessionIDSource,
      batchDecodeFaultController: batchDecodeFaultController)
  }
}
