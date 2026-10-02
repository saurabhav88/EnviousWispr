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

/// #1388 step 3: adapters whose sessionless warm-up includes a cancellable
/// DELIVERY (download) stage in addition to the in-flight model load. The
/// onboarding install Cancel discovers this via `as?` so it can cancel
/// whichever stage the warm-up is currently awaiting. The plain session
/// cancel (`cancel()`) deliberately does NOT touch the delivery — a
/// cancelled recording must not kill a first-run download in progress.
@MainActor
protocol ASREngineWarmupCancelling: AnyObject {
  func cancelSessionlessWarmup() async
}

/// #3338 PR-4 (plan E.1/E.2, K5): what the learn hold may keep from a take, as the
/// adapter saw it. Only the winning, committed decode's own input and output; never
/// recomputed. `samples` is the exact buffer that decode received.
struct LearnDecodeEvidence: Sendable {
  enum Attempt: Sendable, Equatable {
    /// The session's batch decode.
    case batch
    /// The batch decode that rescued a failed or empty streaming finalize.
    case streamingRescue
    /// A Phase 2 retry decode of caller-supplied input.
    case retry
  }

  let samples: [Float]
  let attempt: Attempt
  /// `true` when the caller handed the samples in (`batchSamples` / retry input);
  /// `false` when the adapter fell back to its own retained PCM.
  let callerSupplied: Bool
  /// `TranscriptionOptions.language` as passed to the decode, snapshotted before it ran.
  let language: String?
  let rawText: String
  let wordTimings: [ASRWordTiming]?
}

/// #3338 PR-4: per-session limits for learn evidence. `nil` policy = keep nothing.
struct LearnEvidencePolicy: Sendable, Equatable {
  /// Evidence longer than this is not kept at all (never truncated).
  let maxSamples: Int
}

/// #3338 PR-4: adapters that can hand the learn hold the winning decode's exact input.
/// Discovered by `as?` like the other optional capabilities. Parakeet conforms;
/// WhisperKit does not (its decode ignores the kernel's batch buffer), so its takes
/// keep nothing. A successful STREAMING finalize keeps nothing either: the adapter
/// cannot name the exact samples the streaming decoder consumed (plan §16, 2026-10-02).
@MainActor
protocol ASREngineLearnAudioEvidenceProviding: AnyObject {
  /// The current session's policy; set after `beginSession`, cleared by the next one.
  func setLearnEvidencePolicy(_ policy: LearnEvidencePolicy?)
  /// Evidence of the decode the adapter last COMMITTED for the current session, or
  /// `nil` (no policy, over the cap, streaming success, failure, empty, cancelled or stale).
  var lastLearnEvidence: LearnDecodeEvidence? { get }
}
