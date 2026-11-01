import CoreML
import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation

/// The one owner of the Silero VAD settings dictation ships (#4254): the manager's positive
/// threshold and the streaming segmentation. `SilenceDetector` (dictation) and
/// `MeetingSpeechDetector` (meeting Whisper) both read them here, so the two detectors cannot
/// drift apart. The input conditioning both apply is `VADInputHighPass`; the 1,600-sample
/// expansion of a kept range is a later, separate step (`AudioConstants.speechPaddingSamples`).
enum SpeechVADSettings {
  /// The manager for a loaded model, with the shipped positive threshold.
  static func manager(model: sending MLModel) -> VadManager {
    // `defaultThreshold: 0.5` is our shipped positive entry threshold;
    // FluidAudio's own default is 0.85 (`VadTypes.swift`, `VadConfig.init`).
    // The #1784 audit found NO recorded measurement comparing the two. 0.5
    // first appears in `fb6c254a` (2026-02-18), the commit that introduced
    // `SilenceDetector`. Treat it as shipped-and-unvalidated — not a dependency
    // default, and not established soft-phoneme tuning. Do not cite a
    // rationale for it that this file (moved from `SilenceDetector`, #4254) does not contain.
    //
    // FluidAudio reads it as the positive streaming threshold when
    // `VadSegmentationConfig.negativeThreshold` is nil; the negative exit
    // threshold is DERIVED from it separately, so this value moves both
    // edges (`VadManager+Streaming.swift`, `streamingStateMachine`). The
    // user-facing "sensitivity" control never reaches it — that feeds only
    // the smoothed-EMA auto-stop path in `SilenceDetector`, via `fromSensitivity`.
    //
    // `VadConfig.computeUnits` is deliberately NOT set here: this pre-loaded
    // initializer stores the config and never reads that field (it is read
    // only inside `loadUnifiedModel`, which this path never calls), so
    // setting it would be a silent no-op. The model's real compute policy is
    // pinned at its single construction site, `BundledVADModelLoader`.
    return VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: model)
  }

  /// The streaming segmentation for a minimum silence of `minSilence` seconds (dictation passes
  /// its silence timeout).
  static func segmentation(minSilence: TimeInterval) -> VadSegmentationConfig {
    // `speechPadding: 0.0` puts the boundary exactly at the chunk where
    // probability crossed threshold (no library-default 100ms back-dating).
    // The library's 100ms is NOT dropped — it is applied one layer down, at the
    // trim stage, by `SampleFilter.filter(padding:)` (default 1600 samples).
    // Padding here too would add a SECOND 100ms expansion at each retained
    // boundary. Not strictly a doubling: the filter no-ops on empty segments
    // (`guard !segments.isEmpty else { return allSamples }`), clamps at buffer
    // edges, and merges overlapping ranges, any of which absorbs part of it.
    //
    // Why 0.0 and not FluidAudio's 0.1, and what that evidence does NOT cover.
    // Codex round-2 (2026-05-04) raised the hypothetical that 0.0 clips soft
    // leading phonemes; the same-day corpus run did not show it. Of four English
    // cases, three were wrong before the change and all four were correct after
    // (two of the three had lost a LEADING word, the edge this setting governs;
    // the third lost a trailing clause). Eight French cases kept their leading
    // words; PT and PL spot-checks were clean (#604 / PR #613 — see that PR's
    // per-phrase table, the primary source).
    //
    // That corpus predates a REAL leading-loss case it never tested. #843 later
    // found soft vowel-initial words ("Actually", "Overall") sitting just before
    // the first VAD segment and being trimmed anyway, despite SampleFilter's
    // 100 ms — mitigated downstream by the raw-capture fallback documented in
    // `CapturedAudioConditioner` (see its Step 2a). Whether segmentation padding
    // here would ALSO help that case was never measured.
    //
    // So: do not flip this to 0.1 on the old hypothetical, which was tested and
    // not shown. Do not treat the question as closed either — a change here needs
    // its own measurement against the #843 case, and must account for the second
    // 100 ms expansion it would add at each retained boundary.
    // Re-audited 2026-07-30 (#1784) with no change.
    return VadSegmentationConfig(
      minSpeechDuration: 0.3,
      minSilenceDuration: minSilence,
      speechPadding: 0.0
    )
  }
}
