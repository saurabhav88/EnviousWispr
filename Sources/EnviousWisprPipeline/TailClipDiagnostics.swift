import EnviousWisprCore
import Foundation

/// Numbers-only end-of-dictation tail-clip diagnostics (#1232).
///
/// Classifies a finished dictation as clean / suspected capture-clip /
/// suspected ASR-drop from signals already in hand at ASR completion, so the
/// recurring lost-last-words problem can be triaged from logs/telemetry WITHOUT
/// saving audio. Pure + `nonisolated` so the classifier boundary cases unit-test
/// without spinning up a kernel. Release-safe: only counts, durations, and
/// energy — never audio samples or transcript text.
///
/// Three host-side signals (the cross-process capture-append counter, "#4", is a
/// separate follow-up — see docs/feature-requests/plan-2026-06-28-tailclip-measurement4-append-stats.md):
/// `trailingSilenceMs` is a GATE only (it is ~0 by design whenever speech is
/// still open at stop, because VAD finalize closes the open segment at the raw
/// end). The lead discriminators are tail energy (was the buffer still loud at
/// the very end?) and the ASR last-token gap (did decoded text reach the audio end?).
struct TailClipDiagnostics: Sendable, Equatable {
  enum Classification: String, Sendable {
    case clean
    case suspectedCaptureClip = "suspected_capture_clip"
    case suspectedASRDrop = "suspected_asr_drop"
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
  let asrLastTokenGapMs: Int?
  let asrChunked: Bool?
  let classification: Classification

  /// 16 samples per millisecond at the 16 kHz ASR sample rate.
  static let samplesPerMs = 16
  /// FluidAudio routes audio above this through its multi-window ChunkProcessor
  /// (`ASRConstants.maxModelSamples`, 240k = 15s). Mirrors that constant.
  static let chunkThresholdSamples = 240_000

  // MARK: - Classification thresholds (CALIBRATION CANDIDATES — see issue #1232)
  // Tune from the first 200-500 dogfood dictations.
  static let gateSilenceMs = 40
  static let cleanSilenceMs = 150
  static let tokenGapClipMaxMs = 300
  static let tokenGapDropMinMs = 500

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
    // Dead-air verdict over the 400ms tail via the SHARED #964 helper, so it
    // checks peak, whole-slice RMS, AND the loudest-40ms-window RMS. A faint
    // last word concentrated in one window stays below the whole-slice RMS/peak
    // floors but lifts a local window — the scalar-only check would have hidden
    // that clip as `.clean` (Codex P2). Delegating keeps this from drifting from
    // the no-speech gate.
    let tailIsDeadAir = RecordingSessionKernel.rawAudioIsDeadAir(tail400, peak: peak400)

    let asrInputDurationMs = decodedInputSampleCount.map { $0 / samplesPerMs }
    let gapMs: Int? =
      asrInputDurationMs.flatMap { dur in lastTokenEndMs.map { Swift.max(0, dur - $0) } }
    let chunked = decodedInputSampleCount.map { $0 > chunkThresholdSamples }

    let classification = classify(
      trailingSilenceMs: trailingSilenceMs,
      tailIsDeadAir: tailIsDeadAir,
      lastTokenGapMs: gapMs)

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

  /// Pure classifier. `tailIsDeadAir` is the shared #964 dead-air verdict over
  /// the tail slice (computed in `compute`), so this never drifts from the
  /// no-speech gate.
  static func classify(
    trailingSilenceMs: Int?,
    tailIsDeadAir: Bool,
    lastTokenGapMs: Int?
  ) -> Classification {
    // Clean: a clear trailing-silence cushion means the user finished and paused.
    if let ts = trailingSilenceMs, ts >= cleanSilenceMs { return .clean }
    // Clean: a dead-air tail (no recoverable energy in the last 400ms) — nothing was cut.
    if tailIsDeadAir { return .clean }

    // Past here the tail is energetic. The gate requires the buffer to actually
    // end on speech (little/no trailing silence); without a VAD segment we
    // cannot establish the gate, so we cannot accuse the capture/decode.
    guard let ts = trailingSilenceMs, ts <= gateSilenceMs else { return .unknown }

    // Discriminate by how far the decoded text reached vs the audio end.
    if let gap = lastTokenGapMs {
      if gap <= tokenGapClipMaxMs { return .suspectedCaptureClip }
      if gap >= tokenGapDropMinMs { return .suspectedASRDrop }
    }
    return .unknown
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
