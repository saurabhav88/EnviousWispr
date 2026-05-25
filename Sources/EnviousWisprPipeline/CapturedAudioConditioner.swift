import EnviousWisprCore
import Foundation

// MARK: - CapturedAudioConditioner (epic #827, PR-4.5 #5)
//
// Restores the VAD-segment filtering + too-aggressive-filter raw fallback +
// short-utterance padding the old Parakeet pipeline
// applied before handing samples to ASR. PR-3's fresh kernel kept only the
// yes/no VAD-evidence gate; the adapter then transcribed raw retained PCM,
// so common short utterances ("yes", "no", "hey") could fail outright when
// the raw count was sub-minimum, and VAD-filtered audio never reached ASR.
//
// Placement: kernel-adjacent (NOT inside an `ASREngineAdapter` conformer).
// The adapter contract says an adapter owns its own ASR and rescue; it does
// NOT own capture/VAD policy. A shared kernel-side conditioner means PR-5
// WhisperKit inherits parity without re-duplicating the logic.
//
// Built ON the existing `SampleFilter.filter` (the VAD-segment merge), wrapped
// to return both the ASR-ready samples AND the metadata-only telemetry fields
// §8 of the PR-4.5 plan calls for.

/// One conditioning result — ASR-ready samples plus the metadata-only fields
/// the kernel's telemetry needs to make a future short-utterance regression
/// debuggable. No audio content escapes this struct; counts and booleans only.
public struct ConditionedAudio: Equatable, Sendable {
  /// The samples to pass to ASR for batch rescue. May equal `rawSamples`
  /// (no segments OR too-aggressive-filter raw fallback fired) OR be
  /// VAD-filtered, with or without short-utterance padding appended.
  public let samples: [Float]

  /// Sample count after `SampleFilter.filter` but BEFORE raw fallback and
  /// before silence padding. Equals `rawSamples.count` when no segments were
  /// supplied (the filter is a no-op). Lets telemetry distinguish
  /// "filter ran and trimmed to N" from "filter no-op'd".
  public let filteredSampleCount: Int

  /// `true` when filtering dropped samples below the ASR minimum AND raw
  /// samples meet the minimum, so the conditioner returned raw instead.
  /// Matches the old Parakeet pipeline's raw-fallback branch.
  public let usedRawFallbackAfterVAD: Bool

  /// `true` when the final sample count was below the ASR minimum and the
  /// conditioner appended silence to reach it. Matches the old Parakeet
  /// pipeline's short-utterance padding.
  public let samplesPaddedToMinimum: Bool

  /// Final sample count of `samples` — redundant with `samples.count` but
  /// kept explicit so the telemetry surface does not depend on whether the
  /// caller bothered to recompute.
  public var finalSampleCount: Int { samples.count }
}

/// Apply VAD-segment filtering, too-aggressive-filter raw fallback, and
/// short-utterance padding in the order the old pipeline did (PR-4.5 plan
/// §3 #5 + §5b). Pure function; safe to call from any actor.
public enum CapturedAudioConditioner {

  /// Condition `rawSamples` for ASR batch rescue. When `vadSegments` is empty
  /// the VAD-filter step is a no-op (the kernel passes empty segments when no
  /// VAD detector ran); fallback and padding still apply.
  ///
  /// `minimumSamples` defaults to `AudioConstants.minimumTranscriptionSamples`
  /// — both ASR backends require ≥1 s of audio. Tests may override.
  public static func condition(
    rawSamples: [Float],
    vadSegments: [SpeechSegment],
    minimumSamples: Int = AudioConstants.minimumTranscriptionSamples
  ) -> ConditionedAudio {
    // Step 1: VAD-segment filter.
    // `SampleFilter.filter` already returns `rawSamples` unchanged when
    // segments are empty OR when total voiced audio is sub-threshold — the
    // "too-aggressive-filter" raw fallback at the SampleFilter layer.
    let filtered = SampleFilter.filter(from: rawSamples, segments: vadSegments)
    let filteredCount = filtered.count

    // Step 2: too-aggressive-filter raw fallback at the conditioner layer
    //. Even with non-empty
    // segments, SampleFilter's merge can produce fewer than `minimumSamples`
    // if voiced regions were sparse. If raw audio would meet the minimum,
    // prefer raw — losing words is worse than ASR seeing extra silence.
    var working = filtered
    var usedRawFallback = false
    if working.count < minimumSamples && rawSamples.count >= minimumSamples {
      working = rawSamples
      usedRawFallback = true
    }

    // Step 3: short-utterance padding. For genuinely short audio
    // (single-word: "hey", "hi") pad with silence so ASR's minimum-length
    // contract is satisfied. Guard `count > 0` so a degenerate empty input
    // does not become a buffer of pure silence — the kernel's empty check
    // upstream already routes that to a terminal.
    var padded = false
    if working.count > 0 && working.count < minimumSamples {
      working.append(contentsOf: [Float](repeating: 0, count: minimumSamples - working.count))
      padded = true
    }

    return ConditionedAudio(
      samples: working,
      filteredSampleCount: filteredCount,
      usedRawFallbackAfterVAD: usedRawFallback,
      samplesPaddedToMinimum: padded)
  }
}
