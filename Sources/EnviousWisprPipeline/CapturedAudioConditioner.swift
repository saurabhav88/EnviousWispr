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

  /// `true` when #843 soft-onset preservation fired — a short take whose VAD
  /// filter would have dropped a large early-onset prefix, so the conditioner
  /// returned the full raw capture to keep the soft leading word ("Actually",
  /// "Overall"). Distinct from `usedRawFallbackAfterVAD`, which fires only when
  /// the filtered audio itself fell below the ASR minimum.
  public let usedRawSoftOnsetPreservation: Bool

  /// `true` when the final sample count was below the ASR minimum and the
  /// conditioner appended silence to reach it. Matches the old Parakeet
  /// pipeline's short-utterance padding.
  public let samplesPaddedToMinimum: Bool

  /// #950 — count of trailing raw samples the VAD trim discarded after the last
  /// valid voiced segment's padded end. `0` when the filter no-op'd
  /// (empty / sub-4800-voiced / malformed segments) OR a raw-keeping path fired
  /// (`usedRawFallbackAfterVAD` / `usedRawSoftOnsetPreservation`, which feed the
  /// FULL raw buffer to ASR). Metadata only; diagnostic counterpart to
  /// `filteredSampleCount`. Computed by `droppedTrailingSamples`.
  public let droppedTailSampleCount: Int

  /// Final sample count of `samples` — redundant with `samples.count` but
  /// kept explicit so the telemetry surface does not depend on whether the
  /// caller bothered to recompute.
  public var finalSampleCount: Int { samples.count }

  /// Human-readable label of which conditioning path produced `samples`, for
  /// telemetry/triage. Soft-onset preservation and the too-aggressive fallback
  /// both yield raw audio but for different reasons; `filteredSampleCount`
  /// distinguishes a genuine trim from a no-op passthrough.
  public var conditioningReason: String {
    if usedRawSoftOnsetPreservation { return "rawSoftOnset" }
    if usedRawFallbackAfterVAD { return "rawFallbackTooAggressive" }
    if samplesPaddedToMinimum { return "filteredPaddedToMinimum" }
    return "filtered"
  }
}

/// Apply VAD-segment filtering, too-aggressive-filter raw fallback, and
/// short-utterance padding in the order the old pipeline did (PR-4.5 plan
/// §3 #5 + §5b). Pure function; safe to call from any actor.
enum CapturedAudioConditioner {

  /// Condition `rawSamples` for ASR batch rescue. When `vadSegments` is empty
  /// the VAD-filter step is a no-op (the kernel passes empty segments when no
  /// VAD detector ran); fallback and padding still apply.
  ///
  /// `minimumSamples` defaults to `AudioConstants.minimumTranscriptionSamples`
  /// — both ASR backends require ≥1 s of audio. Tests may override.
  static func condition(
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

    var working = filtered
    var usedRawFallback = false
    var usedRawSoftOnset = false
    let rawMeetsMinimum = rawSamples.count >= minimumSamples

    // Step 2a: #843 soft-onset preservation. A soft vowel-initial leading word
    // ("Actually", "Overall") sits just before the first VAD segment and the
    // filter trims it away. When a SHORT take's speech starts EARLY and the
    // filter would drop a LARGE fraction of the raw audio, that dropped prefix
    // is very likely the real onset — feed the full raw capture to ASR instead.
    // Parakeet handles the extra leading silence and returns empty on true
    // silence/noise (verified on synthetic probes + 65 competitor clips).
    // R3 (Codex): only when raw ALREADY meets the ASR minimum, so this branch
    // never routes a sub-minimum buffer into the Step 3 zero-padding below — the
    // RNNT decoder-loop hazard (gotchas-audio: "Do not pad silence").
    if rawMeetsMinimum,
      shouldPreserveSoftOnset(
        rawCount: rawSamples.count,
        filteredCount: filteredCount,
        vadSegments: vadSegments)
    {
      working = rawSamples
      usedRawSoftOnset = true
    } else if working.count < minimumSamples && rawMeetsMinimum {
      // Step 2b: too-aggressive-filter raw fallback (pre-existing). Even with
      // non-empty segments, SampleFilter's merge can produce fewer than
      // `minimumSamples` if voiced regions were sparse. Prefer raw — losing
      // words is worse than ASR seeing extra silence.
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

    // #950 tail-trim diagnostic. 0 on the raw-keeping paths (we fed the FULL raw
    // buffer to ASR, so nothing was dropped); else what the VAD trim discarded
    // after the last valid voiced segment's padded end.
    let droppedTail =
      (usedRawFallback || usedRawSoftOnset)
      ? 0
      : droppedTrailingSamples(rawSampleCount: rawSamples.count, vadSegments: vadSegments)

    return ConditionedAudio(
      samples: working,
      filteredSampleCount: filteredCount,
      usedRawFallbackAfterVAD: usedRawFallback,
      usedRawSoftOnsetPreservation: usedRawSoftOnset,
      samplesPaddedToMinimum: padded,
      droppedTailSampleCount: droppedTail)
  }

  /// #950 — trailing raw samples discarded by the VAD trim after the last valid
  /// voiced segment's padded end. Mirrors `SampleFilter.filter`'s no-op rules so
  /// it never reports a phantom drop the filter did not actually make: skips
  /// malformed segments (`endSample <= startSample`), returns `0` when total
  /// valid voiced audio is `< 4800` (the filter returns raw there). All counts
  /// are 16kHz mono scalar samples; `padding` matches `SampleFilter`'s default.
  /// Overflow-hardened to parity with `SampleFilter` (#387) — pure, total.
  static func droppedTrailingSamples(
    rawSampleCount: Int, vadSegments: [SpeechSegment], padding: Int = 1600
  ) -> Int {
    guard !vadSegments.isEmpty else { return 0 }
    var voiced = 0  // saturates at 4800 (only the >=4800 gate cares)
    var lastEnd = 0  // true max valid endSample, independent of voiced saturation
    for segment in vadSegments where segment.endSample > segment.startSample {
      lastEnd = max(lastEnd, segment.endSample)
      if voiced < 4800 {
        let (len, lenOverflow) =
          segment.endSample.subtractingReportingOverflow(segment.startSample)
        let (sum, sumOverflow) = voiced.addingReportingOverflow(lenOverflow ? 4800 : len)
        voiced = (lenOverflow || sumOverflow) ? 4800 : sum
      }
    }
    guard voiced >= 4800 else { return 0 }
    let (paddedEnd, endOverflow) = lastEnd.addingReportingOverflow(max(0, padding))
    let keptThrough = endOverflow ? rawSampleCount : min(rawSampleCount, paddedEnd)
    return max(0, rawSampleCount - keptThrough)
  }

  // MARK: #843 soft-onset preservation

  /// Thresholds for soft-onset preservation. Derived from the empirical capture
  /// audit on #843: the dropped "Actually"/"Overall" takes were short (≤2.7 s),
  /// their single VAD segment started early, and the trim removed 55-63% of the
  /// raw audio. Deliberately conservative so a long dictation's legitimate
  /// trailing-silence trim is never mistaken for onset loss.
  enum SoftOnset {
    /// Only short takes. A long dictation dropping ≥25% is real silence trim,
    /// not a clipped first word.
    static let maxRawSamples = Int(8 * AudioConstants.sampleRate)  // 8.0 s
    /// The earliest segment must start within this window for the dropped
    /// prefix to be a plausible onset rather than a long pre-speech pause.
    static let maxFirstSegmentStartSample = Int(2 * AudioConstants.sampleRate)  // 2.0 s
    /// Fraction of raw the filter must drop before we treat it as onset loss.
    static let minDroppedFraction = 0.25
  }

  /// True when the VAD filter looks like it clipped a soft leading word: a short
  /// take, with at least one segment that starts early, where filtering dropped
  /// a large fraction of the raw audio. Pure + internal so the boundary cases
  /// (drop% / segment-start / raw-length, each just below and just above the
  /// threshold) unit-test directly.
  static func shouldPreserveSoftOnset(
    rawCount: Int, filteredCount: Int, vadSegments: [SpeechSegment]
  ) -> Bool {
    guard rawCount > 0, rawCount <= SoftOnset.maxRawSamples else { return false }
    // Earliest segment start (segments are not guaranteed sorted).
    guard let firstStart = vadSegments.map(\.startSample).min() else { return false }
    guard firstStart < SoftOnset.maxFirstSegmentStartSample else { return false }
    // Filtering dropped ≥ minDroppedFraction of the raw audio. (When the filter
    // no-op'd — empty/sub-threshold segments — filteredCount == rawCount, so the
    // drop is 0 and this is false.)
    let dropped = rawCount - filteredCount
    return Double(dropped) >= SoftOnset.minDroppedFraction * Double(rawCount)
  }
}
