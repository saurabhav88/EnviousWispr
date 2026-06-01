import EnviousWisprCore
import Foundation

// PR-5 Rung 5 (#827) — optional adapter capabilities the kernel-side wiring
// discovers via `as?` casts. Engines opt in by extending the adapter file
// with the appropriate `extension` declaration. Parallel to (but separate
// from) `ASREngineTelemetryProviding` in `KernelTelemetryState.swift` because
// these protocols expose control data (LID result) not telemetry.
//
// #879: `ASREngineCacheModelLoadable` (the cache-only silent pre-load command)
// was removed — the launch warm-up now routes through the shared
// `KernelDictationDriver.ensureEngineWarm(reason:)`.

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
