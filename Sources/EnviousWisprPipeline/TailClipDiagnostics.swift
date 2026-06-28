import EnviousWisprCore
import Foundation

/// Numbers-only end-of-dictation tail-clip diagnostics (#1232, recalibrated #1236).
///
/// Labels a finished dictation `asr_complete` / `suspected_asr_drop` / `unknown`
/// from signals already in hand at ASR completion, so the recurring lost-last-words
/// problem can be triaged from logs/telemetry WITHOUT saving audio. Pure +
/// `nonisolated` so the boundary cases unit-test without a kernel. Release-safe:
/// only counts, durations, and energy — never audio samples or transcript text.
///
/// HONEST SCOPE (validated empirically 2026-06-28 + GPT/Gemini council + Codex):
/// these host-side signals detect ONLY an **ASR/chunking tail drop** — audio that
/// WAS captured and fed to the decoder but never emitted as tokens (the live #1099
/// repro: a 30s chunked dictation, last token at 27.76s of 30.58s of input). A true
/// **capture-layer clip** (the mic delivered-but-not-appended race) is INVISIBLE
/// here: truncated audio makes the decoder reach the truncated end with a tiny gap,
/// indistinguishable from a clean stop. Detecting that needs the deferred
/// delivered-vs-appended counters (#1233). So `asr_complete` means "the decoder
/// transcribed through the end of the audio it was given" — it does NOT certify the
/// capture layer.
///
/// The earlier `suspected_capture_clip` label was REMOVED (#1236): a small token gap
/// means the decoder reached the end = healthy, so flagging it as a capture clip was
/// inverted and fired on ~100% of normal dictations. `trailingSilenceMs` is a raw
/// covariate only — it is ~0 by construction whenever speech is open at stop (VAD
/// finalize closes the open segment at the raw end), so it never gates.
///
/// Lead discriminator: the ASR token gap (`asrInputDurationMs - lastTokenEndMs`). The
/// decoded input is the VAD-FILTERED buffer (trailing silence already trimmed before
/// decode), so the gap is already "untranscribed SPEAKING at the tail" — do NOT
/// subtract `trailingSilenceMs`, which lives on the raw-capture timeline and would
/// cancel a real drop (Codex P2, #1236). Tail energy is the covariate: a large gap
/// with a DEAD-AIR tail is natural trailing silence (complete), not a drop.
struct TailClipDiagnostics: Sendable, Equatable {
  enum Classification: String, Sendable {
    /// The decoder transcribed through the end of the captured audio. Does NOT
    /// certify the capture layer (a mic-cut clip looks identical — see #1233).
    case asrComplete = "asr_complete"
    /// Energetic speech remained after the last transcribed word — the decoder
    /// dropped the tail (the #1099 ASR/chunking drop).
    case suspectedASRDrop = "suspected_asr_drop"
    /// Not enough authoritative signal to judge (non-Parakeet-batch decode, or the
    /// gray band between the thresholds).
    case unknown
  }

  let trailingSilenceMs: Int?
  let tail200RMS: Float
  let tail200Peak: Float
  let tail400RMS: Float
  let tail400Peak: Float
  /// Nil unless the decoded ASR input is authoritative (Parakeet batch, unpadded).
  /// For WhisperKit (decodes its own raw/padded buffer), streaming (live feed),
  /// and padded-to-minimum short utterances, `asrSamples` is NOT what the engine
  /// decoded / includes synthetic silence, so these would be wrong — omit.
  let asrInputDurationMs: Int?
  let asrLastTokenEndMs: Int?
  /// The ASR token gap on the decoded (VAD-filtered) timeline = untranscribed
  /// speaking at the tail. The headline ASR-drop metric. Nil when not authoritative.
  let asrLastTokenGapMs: Int?
  let asrChunked: Bool?
  let classification: Classification

  /// 16 samples per millisecond at the 16 kHz ASR sample rate.
  static let samplesPerMs = 16
  /// FluidAudio routes audio above this through its multi-window ChunkProcessor
  /// (`ASRConstants.maxModelSamples`, 240k = 15s). Mirrors that constant.
  static let chunkThresholdSamples = 240_000

  // MARK: - Classification thresholds (CALIBRATION CANDIDATES — see #1236)
  // Empirical 2026-06-28: clean dictations sat at untranscribed-tail 0-185ms; the
  // one real drop at 2825ms; a marginal synthetic at 556ms. Tune from the first
  // 200-500 dogfood dictations once the recalibrated signal accumulates.
  /// At/under this much untranscribed speaking tail, the decoder reached the end.
  static let asrCompleteMaxMs = 250
  /// At/over this much energetic untranscribed tail, the decoder dropped it.
  static let asrDropMinMs = 500

  /// - Parameter decodedInputSampleCount: the sample count the engine ACTUALLY
  ///   decoded, or nil when that is not the unpadded conditioned batch buffer
  ///   (WhisperKit, streaming, padded short utterance) — ASR-input fields omitted.
  static func compute(
    rawSamples: [Float],
    vadSegments: [SpeechSegment],
    decodedInputSampleCount: Int?,
    lastTokenEndMs: Int?
  ) -> TailClipDiagnostics {
    let rawCount = rawSamples.count

    let trailingSilenceMs: Int?
    if let lastEnd = vadSegments.map(\.endSample).max() {
      trailingSilenceMs = max(0, (rawCount - lastEnd) / samplesPerMs)
    } else {
      trailingSilenceMs = nil
    }

    let (rms200, peak200) = energy(of: rawSamples.suffix(200 * samplesPerMs))
    let tail400 = Array(rawSamples.suffix(400 * samplesPerMs))
    let (rms400, peak400) = energy(of: tail400[...])
    // Dead-air verdict over the 400ms tail via the SHARED #964 helper (peak,
    // whole-slice RMS, AND loudest-40ms-window RMS) — the covariate that separates
    // a genuine ASR drop (energetic tail) from a user trailing off into silence
    // (dead-air tail), without drifting from the no-speech gate.
    let tailIsDeadAir = RecordingSessionKernel.rawAudioIsDeadAir(tail400, peak: peak400)

    let asrInputDurationMs = decodedInputSampleCount.map { $0 / samplesPerMs }
    // The gap is measured on the decoded (VAD-filtered) timeline; do NOT subtract
    // raw trailingSilenceMs — the filtered buffer already excludes it, and mixing
    // timelines would cancel a real drop (Codex P2, #1236).
    let gapMs: Int? =
      asrInputDurationMs.flatMap { dur in lastTokenEndMs.map { Swift.max(0, dur - $0) } }
    let chunked = decodedInputSampleCount.map { $0 > chunkThresholdSamples }

    let classification = classify(
      lastTokenGapMs: gapMs,
      tailIsDeadAir: tailIsDeadAir)

    return TailClipDiagnostics(
      trailingSilenceMs: trailingSilenceMs,
      tail200RMS: rms200, tail200Peak: peak200,
      tail400RMS: rms400, tail400Peak: peak400,
      asrInputDurationMs: asrInputDurationMs,
      asrLastTokenEndMs: lastTokenEndMs,
      asrLastTokenGapMs: gapMs,
      asrChunked: chunked,
      classification: classification)
  }

  /// Pure classifier. `lastTokenGapMs` is the untranscribed speaking tail on the
  /// decoded timeline; `tailIsDeadAir` is the shared #964 dead-air verdict.
  static func classify(
    lastTokenGapMs: Int?,
    tailIsDeadAir: Bool
  ) -> Classification {
    // No authoritative token timing (WhisperKit / streaming / padded) — cannot
    // judge the ASR tail.
    guard let gap = lastTokenGapMs else { return .unknown }
    // A dead-air tail means the audio ended in silence: the decoder stopping at
    // the last spoken word is correct, nothing was dropped, regardless of the gap.
    if tailIsDeadAir { return .asrComplete }
    // Energetic tail: the gap is real untranscribed speaking.
    if gap >= asrDropMinMs { return .suspectedASRDrop }
    if gap <= asrCompleteMaxMs { return .asrComplete }
    return .unknown  // gray band between the thresholds
  }

  /// RMS + peak of a sample slice. Empty slice → zeros.
  static func energy(of slice: ArraySlice<Float>) -> (rms: Float, peak: Float) {
    guard !slice.isEmpty else { return (0, 0) }
    var sumSquares: Float = 0
    var peak: Float = 0
    for s in slice {
      sumSquares += s * s
      peak = Swift.max(peak, Swift.abs(s))
    }
    let rms = (sumSquares / Float(slice.count)).squareRoot()
    return (rms, peak)
  }
}
