import EnviousWisprCore
import Foundation

// PR-5 Rung 5 (#827) — optional adapter capabilities the kernel-side wiring
// discovers via `as?` casts. Engines opt in by extending the adapter file
// with the appropriate `extension` declaration. Parallel to (but separate
// from) `ASREngineTelemetryProviding` in `KernelTelemetryState.swift`
// because (a) these protocols expose control data (LID result, cache
// pre-load) not telemetry, and (b) the cache pre-load is an active
// lifecycle command, not a passive accessor.

/// Adapter-side accessor for the engine's last completed language-detection
/// result. `KernelFinalizationWiring.processText` stamps
/// `LLMPolishStep.languageDetection` from this read before polish runs.
/// Engines with `capabilities.supportsLanguageDetection == false`
/// (Parakeet) do not conform; the wiring's `as?` cast returns nil and the
/// polish step stays nil — Parakeet keeps its legacy prompt path.
@MainActor
protocol ASREngineLanguageIdentifying: AnyObject {
  var lastLanguageDetection: LanguageDetectionResult? { get }
}

/// Adapter-side silent model pre-load. WhisperKit conforms and loads the
/// model into RAM from disk cache only (no network download). Parakeet does
/// not conform — Parakeet's silent load is App-routed via
/// `asrManager.loadModelSilently()`.
///
/// NOT to be confused with `WhisperKitEngineAdapter.warmUpFromCache()`,
/// which is a readiness refresh, NOT a model pre-load (seam audit §1).
@MainActor
protocol ASREngineCacheModelLoadable: AnyObject {
  func prepareModelIfCached() async
}
