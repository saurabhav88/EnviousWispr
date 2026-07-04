import EnviousWisprCore
import Foundation
@preconcurrency import WhisperKit

// MARK: - WhisperKitStreamingSession (#1276 Step 2, PR-2)
//
// The authoritative WhisperKit live-transcription session — the "Live
// transcription" toggle's ON path for a picked (locked) language. Unlike the
// best-effort `WhisperKitIncrementalWorker` (which re-decodes and string-stitches
// a separate tail, structurally producing the mid-phrase-duplication and
// wrong-ending bugs #1276 fixes), this session runs ONE growing decode stream
// compared against ITSELF via segment-count-lag holdback, so neither meshing bug
// can occur by construction: there is never a second independent decode joined
// after the fact.
//
// SHIPPED ALGORITHM (`localAgreement: true` — the UFAL whisper_streaming
// architecture, arXiv 2307.14743; 120-clip founder-audio benchmark winner
// 2026-07-04, trailing-phantom hallucination 1/109 vs 14/109 for the stitch):
//   - Per cycle: pull the adapter-owned lossless `streamingPCM` via the provider;
//     gate on >= 1s of new audio; decode the BUFFER `[bufferStartSec .. end]`
//     with `chunkingStrategy: .none` (NEVER `.vad` — see F2 below). Committed
//     speech stays IN the window (re-decoded, deduplicated at the seam), so the
//     decoder always warms up on known audio and never opens cold on a pause.
//     `language` is the picked code (locked): no LID, no garble.
//   - Confirmation (LocalAgreement-2, UFAL `HypothesisBuffer.flush()`): commit
//     the longest common word prefix of the last two decode hypotheses; hold the
//     unstable remainder for the next cycle. Force-commit words older than the
//     retention line if agreement stalls past `maxUnconfirmedWindowSec`.
//   - Buffer trim: past `bufferTrimSec` the origin advances to the last
//     committed sentence end that keeps `minRetainedBufferSec` of speech in the
//     window; scrolled-out text becomes the conditioning prompt (bounded suffix,
//     `promptTokens`) — its audio is never decoded again.
//   - `finalize` (the adapter drains its feed tasks FIRST, so `streamingPCM` is
//     complete): caught up (no fresh voiced audio since the last decode, by
//     exact sample bookkeeping) → release the hypothesis, zero inference.
//     Fresh speech at stop → ONE bounded buffer decode (see
//     `finalizeLocalAgreement`). `finalSamples` is intentionally IGNORED
//     (single-coordinate design, §3.2): the coordinates were learned from
//     `streamingPCM`, not `finalSamples`.
//
// FALLBACK ALGORITHM (`localAgreement: false` — lifted from WhisperKit's
// `AudioStreamTranscriber` segment-holdback loop, whisperkit-research.md
// FACT: audiostreamtranscriber-actual-mechanism):
//   - Decode the window from `lastConfirmedSec`; if
//     `segments.count > requiredSegmentsForConfirmation` (N=2), freeze the prefix
//     `count-N` segments into confirmed text and advance `lastConfirmedSec`;
//     force-confirm past `maxUnconfirmedWindowSec` (the `.none`-over-30s cost
//     cliff; Codex r1 PARTIAL). `finalize` runs ONE bounded tail decode over
//     `[lastConfirmedSec .. end]` and appends it to the confirmed prefix.
//
// F2: `.none` + clip-seek slices only `audioArray[seek..<seek+window]`, bounded;
// `.vad` re-chunks the whole growing buffer every cycle (O(n^2)), which wedged the
// 10-min benchmark. The base decode options force `.none`; the session never
// re-derives options per cycle (which would flip to `.vad` above 30s).

// MARK: - Tail-finalization benchmark instrumentation (#1276 PR-2, rulebook §5.0)
//
// These types + the `benchmarkCaptureAndStop()` method exist ONLY to let the
// local tail-finalization replay runner (`scripts/eval/tail_runner`) freeze the
// session's state at the certified checkpoint so all four candidate finish
// strategies replay from ONE identical starting point. The shipped `finalize`
// path never touches them. No behavior change to the live pipeline.

/// One retained (held-back / unconfirmed) hypothesis segment — the words the
/// stream was still holding back at stop. This is exactly what a "release-only"
/// finish (arm S1) would emit; retaining it here is what makes that arm
/// measurable (Codex r1: the shipped code discards these, so there was nothing
/// to release).
package struct BenchmarkSegment: Sendable, Equatable {
  package let text: String
  package let start: Float
  package let end: Float
  package init(text: String, start: Float, end: Float) {
    self.text = text
    self.start = start
    self.end = end
  }
}

/// The frozen record captured at the certified checkpoint: after the loop is
/// stopped and awaited, BEFORE any arm-specific finalization / provider drop /
/// `streamingPCM` clear. Carries the actual sample payload (not just a hash) so
/// arms that re-decode (S2/S3/S4) can run from it, plus the confirmed prefix and
/// the retained unconfirmed hypothesis (arm S1's material). `contentHash` +
/// `sampleCount` back the §5.3 replay-fidelity gate.
package struct BenchmarkSnapshot: Sendable {
  package let samples: [Float]
  package let sampleCount: Int
  package let contentHash: UInt64
  package let confirmedText: String
  package let lastConfirmedSec: Float
  package let lastDecodeSampleCount: Int
  package let decodeCount: Int
  package let totalDecodeTimeMs: Int
  package let unconfirmedSegments: [BenchmarkSegment]
  /// UFAL buffer-mode state (zero/"" in segment-lag mode): decode-window origin
  /// and the committed text scrolled out of the buffer (arm S5's prompt).
  package let bufferStartSec: Float
  package let scrolledOutText: String
}

/// The authoritative WhisperKit streaming session. Conforms to the existing
/// `WhisperKitIncrementalSession` seam (#360) so the adapter drives it with the
/// same start/finalize/cancel lifecycle it already understands; the
/// best-effort-vs-authoritative difference lives in the adapter's result handling.
package actor WhisperKitStreamingSession: WhisperKitIncrementalSession {
  private let whisperKit: any WhisperKitTranscribing
  private let baseDecodingOptions: DecodingOptions
  private let cadence: Duration

  /// Segments held back from confirmation each cycle (the "lag"). WhisperKit's
  /// trailing segments are the least stable; keeping the last N unconfirmed and
  /// re-decoding them next cycle is what makes the confirmed prefix stable.
  private let requiredSegmentsForConfirmation: Int

  /// One second of 16 kHz mono audio — the minimum new audio before a cycle
  /// decodes (matches `AudioStreamTranscriber`'s >= 1s gate).
  private let minNewSamplesToDecode = 16_000

  /// Force-confirm bound: when the unconfirmed window (end - `lastConfirmedSec`)
  /// exceeds this, confirm the oldest unconfirmed segment(s) so the per-cycle
  /// decode window stays under one 30s WhisperKit window even if confirmation
  /// stalls. 25s leaves headroom under the 30s window.
  private let maxUnconfirmedWindowSec: Float = 25.0

  /// Minimum uncovered-tail duration (seconds) below which the flush skips the
  /// tail decode and accepts the confirmed prefix — a sub-100ms tail is too short
  /// to carry a word (matches `WhisperKitIncrementalWorker`'s 1600-sample /
  /// ~100ms tail threshold). Above this, a VOICED tail (see `tailEnergyFloor`) is
  /// always decoded so short final words are not dropped (Codex r6 P2); the
  /// hallucination guard is the ENERGY floor, not this duration.
  private let minVoicedTailSec: Float = 0.1

  /// RMS energy floor for the uncovered tail — below this the tail is treated as
  /// silence and the flush skips it (the confirmed prefix is the complete
  /// transcript). Matches `WhisperKitIncrementalWorker`'s tail-decode energy gate
  /// (`rms > 0.001`), so a tail that clears BOTH the duration and energy gates but
  /// still decodes empty is a genuine silent drop → force the batch fallback.
  private let tailEnergyFloor: Float = 0.001

  // MARK: Confirmed-stream state (single owner: the serial loop / finalize)

  /// The frozen, confirmed transcript prefix — confirmed segment texts joined by
  /// spaces. Only ever grows; never re-decoded. The tail decode at finalize
  /// appends to this.
  private var confirmedText: String = ""
  /// End time (seconds, absolute in `streamingPCM`) of the last confirmed
  /// segment. The next decode seeks here (`clipTimestamps = [lastConfirmedSec]`).
  private var lastConfirmedSec: Float = 0
  /// Sample count at the last decode, to gate the >= 1s-new-audio check.
  private var lastDecodeSampleCount: Int = 0
  private var decodeCount: Int = 0
  private var totalDecodeTimeMs: Int = 0

  /// The most recent cycle's held-back (unconfirmed) hypothesis tail.
  /// Overwritten every cycle so it always reflects the latest decode. Read by
  /// TWO consumers: the UFAL-mode finalize releases it as the transcript tail
  /// on the caught-up fast path, and the benchmark replay runner reads it as
  /// arm S1's "release-only" material (rulebook §5.0). The segment-lag
  /// finalize ignores it. Empty until the first decode.
  private var retainedUnconfirmedSegments: [BenchmarkSegment] = []

  private var running = false
  /// Set exactly once at the first terminal (`finalize`/`cancel`) so a late loop
  /// cycle resuming from its decode await drops its result instead of mutating
  /// confirmed state after the transcript was produced (cleanup-once).
  private var finished = false
  private var loopTask: Task<Void, Never>?

  /// The retained audio provider from `start(...)`. The loop pulls it each cycle;
  /// `finalize` pulls it ONCE more for the flush tail — so both the loop and the
  /// flush read the SAME `streamingPCM` coordinate (no cross-buffer mapping).
  private var audioSamplesProvider: (@Sendable () async -> (samples: [Float], count: Int))?

  /// Test-only observability (race-free: reads actor state, which every
  /// assertion depends on, not a proxy for decoder-call timing).
  package var currentDecodeCount: Int { decodeCount }
  package var confirmedTextForTests: String { confirmedText }
  package var lastConfirmedSecForTests: Float { lastConfirmedSec }

  /// `cadence` defaults to the shipped incremental cycle; tests inject a
  /// near-zero value to characterize loop behavior without wall-clock waits.
  /// When true, decodes are conditioned on prior committed text via
  /// `DecodingOptions.promptTokens` (`condition_on_previous_text`). In UFAL
  /// buffer mode only text scrolled OUT of the window is eligible. #1276
  /// investigation: decoding a tail BLIND (no prior-text context) is the cause
  /// of the trailing "thank you" hallucination. ON in the shipped construction
  /// (`WhisperKitBackend.makeStreamingSession`); the parameter default stays
  /// OFF so tests and callers opt in explicitly.
  private let conditionOnPriorText: Bool

  /// When true, confirmation runs the UFAL whisper_streaming architecture
  /// (word-level LocalAgreement-2 over a sentence-trimmed audio buffer) instead
  /// of the segment-count lag + advancing window. Requires `wordTimestamps` in
  /// the decode options (`makeStreamingSession` forces it on); a wordless
  /// decode holds its cycle rather than confirming (see `applyLocalAgreement`).
  /// ON in the shipped construction (the 120-clip benchmark winner,
  /// 2026-07-04); the parameter default stays OFF so tests and callers opt in
  /// explicitly.
  ///
  /// Why the buffer shape matters (measured 2026-07-04): advancing the decode
  /// window to the last committed word and bridging the gap with promptTokens
  /// made the decoder EOT into empty output whenever the window opened on a
  /// pause (WhisperKit `firstTokenLogProbThreshold` fallback trace). The UFAL
  /// recipe instead keeps committed speech IN the window (re-decoded and
  /// deduplicated), so every decode warms up on known audio; the buffer is
  /// trimmed only at committed sentence boundaries once it exceeds
  /// `bufferTrimSec`, and only text scrolled OUT of the buffer becomes the
  /// conditioning prompt.
  private let localAgreement: Bool

  /// Previous cycle's uncommitted word hypothesis (LocalAgreement-2 state):
  /// the words after the committed cut, compared prefix-wise against the next
  /// cycle's post-cut words.
  private var previousHypothesisWords: [WordTiming] = []

  /// Decode-window start (UFAL audio buffer origin). Advances ONLY when the
  /// buffer is trimmed at a committed sentence boundary — never per commit.
  private var bufferStartSec: Float = 0

  /// Committed words whose audio is still inside the buffer (re-decoded every
  /// cycle; used to cut the fresh hypothesis and to pick trim boundaries).
  private var committedWordsInBuffer: [WordTiming] = []

  /// Committed text whose audio has scrolled OUT of the buffer — the ONLY text
  /// eligible as conditioning prompt (UFAL `OnlineASRProcessor.prompt()`).
  private var scrolledOutText: String = ""

  /// Trim the buffer at the last committed sentence end once it grows past
  /// this (UFAL `buffer_trimming_sec`; their default 15s). Keeps the decode
  /// window comfortably under one 30s WhisperKit window.
  private let bufferTrimSec: Float = 15.0

  /// Minimum audio retained in the window after a trim, so the next decode
  /// always opens on recent committed speech rather than cold on a pause
  /// (whisper.cpp streaming's keep-context pattern; see `applyLocalAgreement`
  /// step 3 for the measured failure this prevents).
  private let minRetainedBufferSec: Float = 8.0

  package init(
    whisperKit: any WhisperKitTranscribing,
    decodingOptions: DecodingOptions,
    requiredSegmentsForConfirmation: Int = 2,
    cadence: Duration = .seconds(1),
    conditionOnPriorText: Bool = false,
    localAgreement: Bool = false
  ) {
    self.whisperKit = whisperKit
    self.baseDecodingOptions = decodingOptions
    self.requiredSegmentsForConfirmation = max(1, requiredSegmentsForConfirmation)
    self.cadence = cadence
    self.conditionOnPriorText = conditionOnPriorText
    self.localAgreement = localAgreement
  }

  // MARK: WhisperKitIncrementalSession

  package func start(
    audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)
  ) {
    running = true
    finished = false
    confirmedText = ""
    lastConfirmedSec = 0
    lastDecodeSampleCount = 0
    decodeCount = 0
    totalDecodeTimeMs = 0
    retainedUnconfirmedSegments = []
    previousHypothesisWords = []
    bufferStartSec = 0
    committedWordsInBuffer = []
    scrolledOutText = ""
    self.audioSamplesProvider = audioSamplesProvider

    loopTask = Task { [weak self] in
      guard let self else { return }
      await self.runLoop()
    }
  }

  /// Authoritative flush. The adapter has already drained its feed tasks, so the
  /// retained provider now returns the COMPLETE `streamingPCM`. Stops the loop,
  /// runs one bounded tail decode over `[lastConfirmedSec .. end]`, and appends it
  /// to the confirmed prefix. `finalSamples` is intentionally IGNORED (§3.2
  /// single-coordinate design). The in-flight loop decode (if any) is NOT awaited —
  /// WhisperKit's decode is not cooperatively cancellable mid-run, and the
  /// `finished` flag drops its result — so stop-to-text never wedges on a stuck
  /// cycle.
  // periphery:ignore:parameters finalSamples,speechSegments - single-coordinate design ignores both (§3.2)
  package func finalize(
    finalSamples: [Float],
    speechSegments: [SpeechSegment]
  ) async -> IncrementalResult {
    running = false
    finished = true
    let loop = loopTask
    loopTask?.cancel()
    loopTask = nil

    // Serialize the flush behind any in-flight loop decode (Codex r5 P2).
    // WhisperKit's `transcribe` is NOT cooperatively cancellable mid-run, so
    // cancelling the loop task does not stop an in-flight decode on the shared
    // `whisperKit` instance. Starting the flush tail decode while that decode is
    // still running would put TWO concurrent transcribes on one model session and
    // corrupt decoder state. Await the loop's full exit first: if the loop is
    // sleeping between cycles, `cancel()` interrupts the sleep and this returns
    // immediately; if it is mid-decode, this waits (bounded by that decode) for it
    // to return — the loop then sees `finished` and drops its result without
    // mutating confirmed state. Only then is the flush decode the sole transcribe.
    await loop?.value

    // Capture + drop the provider so a defensive second finalize cannot re-run a
    // tail decode (it returns the confirmed text below instead).
    guard let provider = audioSamplesProvider else {
      // start() was never called, provider dropped, or finalize already ran —
      // nothing to flush.
      return streamingResult(text: confirmedText, samplesCovered: 0, tailDecodeMs: 0)
    }
    audioSamplesProvider = nil
    let (samples, count) = await provider()

    // UFAL buffer mode (localAgreement): its own finalize policy — instant
    // release when the stream is already caught up, else ONE bounded buffer
    // decode. The segment-lag policy below is untouched.
    if localAgreement {
      return await finalizeLocalAgreement(samples: samples, count: count)
    }

    let flushConfirmedSec = lastConfirmedSec
    let durationSec = Float(count) / 16_000.0
    let uncoveredTailSec = durationSec - flushConfirmedSec

    // Tail gate (mirrors `WhisperKitIncrementalWorker`'s tail-decode gate exactly:
    // uncovered > ~100ms AND RMS > 0.001). ENERGY is the silence signal, not
    // duration: skip the flush decode and accept the confirmed prefix as complete
    // ONLY when the uncovered tail is genuine trailing SILENCE (low energy) or is
    // negligibly short (< 100ms, sub-word). A near-silence decode invites the
    // YouTube-corpus "Thank you" hallucination, and a quiet/negligible tail means
    // the prefix already IS the complete transcript. Crucially, a SHORT-BUT-VOICED
    // tail (e.g. a final "yes" at 150-400ms) is NOT skipped — it is decoded below,
    // so short final words are never silently dropped (Codex r6 P2).
    let tailStartIdx = max(0, min(count, Int(flushConfirmedSec * 16_000)))
    let tailSlice = tailStartIdx < count ? Array(samples[tailStartIdx..<count]) : []
    let tailRMS = rms(tailSlice)
    guard uncoveredTailSec >= minVoicedTailSec, tailRMS > tailEnergyFloor, !samples.isEmpty else {
      return streamingResult(
        text: confirmedText, samplesCovered: count, tailDecodeMs: 0)
    }

    let tailStart = CFAbsoluteTimeGetCurrent()
    var opts = baseDecodingOptions
    opts.clipTimestamps = [flushConfirmedSec]
    opts.windowClipTime = 0
    // Pad the flush with 0.5s trailing silence before the tail decode (Codex r3
    // P2) — WhisperKit drops the last words on an unpadded decode when audio ends
    // right after speech, and since a non-empty tail is accepted as authoritative
    // the batch fallback would not repair it. The batch path
    // (`WhisperKitPipelineSpeechRouting.paddedASRSamples`) and the old tail worker
    // both pad; match them. The trailing padding does not shift `clipTimestamps`
    // (a start-seek at `flushConfirmedSec`), and the gate above ran on the
    // UNPADDED audio so the silence never affects the energy/duration decision.
    let paddedSamples = WhisperKitBackend.padAudioWithSilence(samples)
    do {
      let results = try await whisperKit.transcribe(
        audioArray: paddedSamples, decodeOptions: opts)
      let tailText = joinedSegmentText(results)
      let tailMs = Int((CFAbsoluteTimeGetCurrent() - tailStart) * 1000)
      guard !tailText.isEmpty else {
        // A VOICED tail (passed the energy gate) that decodes to nothing is a
        // silent drop, not silence — do NOT ship the truncated prefix (Codex r2
        // P2, mirrors the worker's `tail_empty_fallback`). Force the adapter to
        // re-transcribe the COMPLETE audio via the clean batch fallback.
        return forceFallbackResult(strategy: "streaming_tail_empty_fallback", tailMs: tailMs)
      }
      let combined = appendText(confirmedText, tailText)
      return streamingResult(text: combined, samplesCovered: count, tailDecodeMs: tailMs)
    } catch {
      // Flush tail decode THREW after a prefix was already confirmed (Codex r1 P2)
      // — same reasoning as the empty-tail branch: force the batch fallback rather
      // than ship a prefix missing the unconfirmed tail.
      let tailMs = Int((CFAbsoluteTimeGetCurrent() - tailStart) * 1000)
      return forceFallbackResult(strategy: "streaming_flush_failed", tailMs: tailMs)
    }
  }

  /// UFAL-mode finalize (#1276 PR-2 benchmark winner). Two paths, chosen by
  /// exact sample bookkeeping (never a guessed timeframe):
  ///   - CAUGHT UP (audio since the last decode is negligible or silent —
  ///     the user paused before stopping): release the last hypothesis as-is.
  ///     Zero inference, ~0ms. The 120-clip benchmark showed release-only
  ///     kills the trailing-phantom hallucination (1/109 vs 14/109 shipped).
  ///   - FRESH SPEECH at stop (the user released right on the last word):
  ///     ONE bounded decode of the live buffer `[bufferStartSec .. end]` with
  ///     the scrolled-out conditioning prompt — the same window+prompt the loop
  ///     decoded every cycle, once more over the now-complete audio. NOT a
  ///     re-decode of the recording: scrolled-out audio is never decoded again,
  ///     so cost is bounded by the buffer (≤ ~15s) regardless of dictation
  ///     length. This closes the undecoded-final-chunk drop that pure release
  ///     structurally cannot (benchmark arm S5).
  /// Empty/thrown decode → the same clean-batch fallback as the segment path.
  private func finalizeLocalAgreement(samples: [Float], count: Int) async -> IncrementalResult {
    let releasedTail = retainedUnconfirmedSegments.map(\.text)
      .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    let releaseText = appendText(confirmedText, releasedTail)

    // Exact bookkeeping: audio that arrived after the last decode pulled the
    // buffer. `lastDecodeSampleCount` is the sample count that decode saw.
    let unheardStart = max(0, min(count, lastDecodeSampleCount))
    let unheardSlice = unheardStart < count ? Array(samples[unheardStart..<count]) : []
    let unheardSec = Float(unheardSlice.count) / 16_000.0
    if unheardSec < minVoicedTailSec || rms(unheardSlice) <= tailEnergyFloor || samples.isEmpty {
      // Caught up: everything voiced was decoded; the hypothesis is complete.
      return streamingResult(text: releaseText, samplesCovered: count, tailDecodeMs: 0)
    }

    let tailStart = CFAbsoluteTimeGetCurrent()
    var opts = baseDecodingOptions
    opts.clipTimestamps = [bufferStartSec]
    opts.windowClipTime = 0
    if conditionOnPriorText, !scrolledOutText.isEmpty {
      opts.promptTokens = whisperKit.encodeText(Self.promptSuffix(of: scrolledOutText))
    }
    // Same trailing-silence pad as the segment-path flush (last-word context).
    let paddedSamples = WhisperKitBackend.padAudioWithSilence(samples)
    do {
      let results = try await whisperKit.transcribe(audioArray: paddedSamples, decodeOptions: opts)
      let bufferText = joinedSegmentText(results)
      let tailMs = Int((CFAbsoluteTimeGetCurrent() - tailStart) * 1000)
      guard !bufferText.isEmpty else {
        // Voiced fresh audio decoding to nothing is a silent drop — force the
        // clean-batch fallback rather than ship a truncated transcript.
        return forceFallbackResult(strategy: "streaming_buffer_empty_fallback", tailMs: tailMs)
      }
      // `scrolledOutText` + the buffer decode IS the transcript (confirmedText
      // already contains the scrolled-out prefix — never combine those two).
      let combined = appendText(scrolledOutText, bufferText)
      return streamingResult(text: combined, samplesCovered: count, tailDecodeMs: tailMs)
    } catch {
      let tailMs = Int((CFAbsoluteTimeGetCurrent() - tailStart) * 1000)
      return forceFallbackResult(strategy: "streaming_flush_failed", tailMs: tailMs)
    }
  }

  /// A flush result that forces the adapter to fall back to the clean batch
  /// decode (`accepted: false`). The confirmed prefix is carried only for
  /// diagnostics — the adapter re-transcribes the complete audio, which is both
  /// heart-safe and recovers the dropped tail.
  private func forceFallbackResult(strategy: String, tailMs: Int) -> IncrementalResult {
    let trimmed = confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
    return IncrementalResult(
      text: trimmed.isEmpty ? nil : confirmedText,
      samplesCovered: 0, decodeCount: decodeCount,
      totalDecodeTimeMs: totalDecodeTimeMs,
      accepted: false, mode: "streaming",
      strategy: strategy, tailDecodeMs: tailMs)
  }

  private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return (sumSquares / Float(samples.count)).squareRoot()
  }

  package func cancel() async {
    running = false
    finished = true
    let loop = loopTask
    loopTask?.cancel()
    loopTask = nil
    audioSamplesProvider = nil
    // Await the loop's full exit, exactly like `finalize` (Codex r2 P1):
    // WhisperKit's `transcribe` is not cooperatively cancellable mid-run, so
    // returning while a loop decode is still in flight would let a quick next
    // recording start a SECOND concurrent transcribe on the same model and
    // corrupt decoder state. The loop sees `finished` on resume and drops its
    // result; this wait is bounded by that single decode.
    await loop?.value
  }

  // MARK: - Benchmark capture (rulebook §5.0 / §5.3) — replay runner ONLY.

  /// Freeze the session at the certified checkpoint and return the snapshot.
  /// Mirrors `finalize`'s stop sequence EXACTLY (stop the loop, then
  /// `await loop?.value` so any in-flight decode fully exits before the capture —
  /// no second transcribe races it) but runs NO finalization arm and does NOT
  /// drop the provider: the replay runner runs all four candidate finishes from
  /// the returned snapshot. Because this awaits the loop's exit, an in-flight
  /// decode at stop is DROPPED (the loop sees `finished` and discards its result
  /// without mutating confirmed state), so the snapshot's confirmed prefix and
  /// retained tail are exactly the pre-stop state — never over-advanced. Returns
  /// nil if `start` was never called (or a prior capture/finalize dropped the
  /// provider). Benchmark-only; the shipped pipeline never calls this.
  package func benchmarkCaptureAndStop() async -> BenchmarkSnapshot? {
    running = false
    finished = true
    let loop = loopTask
    loopTask?.cancel()
    loopTask = nil
    await loop?.value

    guard let provider = audioSamplesProvider else { return nil }
    let (samples, count) = await provider()
    return BenchmarkSnapshot(
      samples: samples,
      sampleCount: count,
      contentHash: Self.fnv1a(samples),
      confirmedText: confirmedText,
      lastConfirmedSec: lastConfirmedSec,
      lastDecodeSampleCount: lastDecodeSampleCount,
      decodeCount: decodeCount,
      totalDecodeTimeMs: totalDecodeTimeMs,
      unconfirmedSegments: retainedUnconfirmedSegments,
      bufferStartSec: bufferStartSec,
      scrolledOutText: scrolledOutText)
  }

  /// Stable content hash over the raw sample bits (FNV-1a) — backs the §5.3
  /// replay-fidelity gate (a replayed snapshot's payload must equal a live run's).
  private static func fnv1a(_ samples: [Float]) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for s in samples {
      var bits = s.bitPattern
      for _ in 0..<4 {
        hash = (hash ^ UInt64(bits & 0xff)) &* 0x0000_0100_0000_01b3
        bits >>= 8
      }
    }
    return hash
  }

  // MARK: - Private

  private func runLoop() async {
    while running && !Task.isCancelled {
      try? await Task.sleep(for: cadence)
      guard running && !Task.isCancelled, !finished else { break }
      guard let provider = audioSamplesProvider else { break }

      let (samples, count) = await provider()
      // A terminal (finalize/cancel) may have landed while suspended at the
      // provider await — drop this cycle rather than mutating confirmed state
      // after the transcript was produced (cleanup-once / actor-reentrancy).
      guard running, !finished, !Task.isCancelled else { break }
      guard count - lastDecodeSampleCount >= minNewSamplesToDecode else { continue }

      var opts = baseDecodingOptions
      // UFAL buffer mode decodes the whole retained buffer (origin advances
      // only at sentence trims); the segment-lag mode advances per confirm.
      let windowStart = localAgreement ? bufferStartSec : lastConfirmedSec
      opts.clipTimestamps = [windowStart]
      opts.windowClipTime = 0
      // Prior-text conditioning (under test): ONLY text whose audio has
      // scrolled out of the decode window is eligible (UFAL
      // `OnlineASRProcessor.prompt()`), bounded to a ~200-char suffix — an
      // unbounded prompt destabilizes long dictations (measured 2026-07-04:
      // severe truncation + repetition loops; Whisper's prompt budget is 224
      // tokens). In segment-lag mode the whole confirmed text is out-of-window
      // by construction (window starts at lastConfirmedSec).
      let promptSource = localAgreement ? scrolledOutText : confirmedText
      if conditionOnPriorText, !promptSource.isEmpty {
        opts.promptTokens = whisperKit.encodeText(Self.promptSuffix(of: promptSource))
      }
      let decodeStart = CFAbsoluteTimeGetCurrent()
      do {
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: opts)
        // Re-check terminal state AFTER the decode await before mutating confirmed
        // state — a finalize/cancel during the decode must win.
        guard running, !finished, !Task.isCancelled else { break }
        applyConfirmation(from: results, currentSampleCount: count)
        lastDecodeSampleCount = count
        decodeCount += 1
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - decodeStart) * 1000)
        totalDecodeTimeMs += elapsedMs
      } catch {
        if !Task.isCancelled {
          await AppLogger.shared.log(
            "WhisperKit streaming decode failed: \(error.localizedDescription)",
            level: .info, category: "WhisperKitStreaming")
        }
      }
    }
  }

  /// Freeze the confirmable prefix of this cycle's segments into `confirmedText`
  /// and advance `lastConfirmedSec`. Confirms `count - N` by default, and
  /// force-confirms more if the unconfirmed window would otherwise exceed
  /// `maxUnconfirmedWindowSec`.
  private func applyConfirmation(from results: [TranscriptionResult], currentSampleCount: Int) {
    let segments = results.flatMap { $0.segments }
    guard !segments.isEmpty else { return }

    // LocalAgreement-2 path: owns EVERY decode in buffer mode. Never falls
    // through to the segment path — that path assumes the decode window began
    // at `lastConfirmedSec`, but buffer-mode decodes begin at `bufferStartSec`,
    // so segment-lag confirmation would re-confirm already-committed audio and
    // duplicate the transcript prefix (Codex r1 P2).
    if localAgreement {
      applyLocalAgreement(segments: segments, currentSampleCount: currentSampleCount)
      return
    }

    let latestEnd = max(segments.last?.end ?? lastConfirmedSec, lastConfirmedSec)
    var confirmCount = max(0, segments.count - requiredSegmentsForConfirmation)
    // Force-confirm to keep the unconfirmed window under the bound even if the
    // segment lag alone would confirm too few (stalled confirmation).
    var pendingConfirmedSec = confirmCount > 0 ? segments[confirmCount - 1].end : lastConfirmedSec
    while confirmCount < segments.count,
      latestEnd - pendingConfirmedSec > maxUnconfirmedWindowSec
    {
      pendingConfirmedSec = segments[confirmCount].end
      confirmCount += 1
    }

    // Retain the held-back tail (everything not confirmed this cycle) for the
    // benchmark's release-only arm. Set BEFORE the confirmCount>0 guard so a
    // cycle that confirms nothing still records all segments as held back
    // (rulebook §5.0). Shipped finalize never reads this.
    retainedUnconfirmedSegments = segments[confirmCount...].map {
      BenchmarkSegment(text: $0.text, start: $0.start, end: $0.end)
    }

    guard confirmCount > 0 else { return }

    for segment in segments[0..<confirmCount] {
      confirmedText = appendText(confirmedText, segment.text)
    }
    // Monotonic guard: never move the confirmed second backwards.
    lastConfirmedSec = max(lastConfirmedSec, segments[confirmCount - 1].end)
  }

  /// UFAL whisper_streaming confirmation (port of `HypothesisBuffer.insert()`
  /// + `flush()` + `OnlineASRProcessor` buffer trimming). Each cycle re-decodes
  /// the WHOLE buffer `[bufferStartSec .. end]` — committed speech stays in the
  /// window so the decoder always warms up on known audio (never opens on a
  /// pause; that's what emptied conditioned decodes on 2026-07-04):
  ///   1. CUT: drop hypothesis words that re-cover already-committed audio
  ///      (timestamp filter at the last committed end, then a 1..5-gram text
  ///      dedup at the seam — `HypothesisBuffer.insert`'s jitter guard).
  ///   2. FLUSH: commit the longest common word prefix of this cut hypothesis
  ///      and the previous cycle's (LocalAgreement-2).
  ///   3. TRIM: once the buffer exceeds `bufferTrimSec`, advance
  ///      `bufferStartSec` to the last committed sentence end (`.?!`), moving
  ///      the words before it out of the buffer; their text becomes prompt
  ///      material (`scrolledOutText`). Force-trim at the last committed word
  ///      if the buffer passes `maxUnconfirmedWindowSec` with no sentence end.
  /// A decode with NO word timings (a `wordTimestamps` misconfiguration —
  /// `makeStreamingSession` forces it on) holds the cycle: no commit, no state
  /// change. Persistently wordless decodes therefore never confirm anything and
  /// finalize fails open to the clean-batch fallback.
  private func applyLocalAgreement(
    segments: [TranscriptionSegment], currentSampleCount: Int
  ) {
    let allWords = segments.flatMap { $0.words ?? [] }
    guard !allWords.isEmpty else { return }

    func trimmed(_ w: WordTiming) -> String {
      w.word.trimmingCharacters(in: .whitespaces)
    }

    // 1. CUT — timestamp filter: keep only words past the committed cut
    // (0.1s tolerance for re-decode jitter, as in `HypothesisBuffer.insert`)
    // and inside REAL audio (a word stamped past the buffered sample count is
    // a hallucination in the 30s window's silence padding — never commit it).
    // A word that STARTS inside real audio but whose END stretched into the
    // padding is kept with its end CLAMPED to real audio (cloud review P1):
    // committing an out-of-range end would poison `committedEnd` and cut every
    // subsequent real word (the filter below compares against it), stalling
    // the stream. Clamping (not dropping) also protects a genuine final word
    // whose timestamp merely bled into the trailing pad.
    let realAudioEndSec = Float(currentSampleCount) / 16_000.0
    let committedEnd = committedWordsInBuffer.last?.end ?? bufferStartSec
    var words =
      allWords
      .filter { $0.start >= committedEnd - 0.1 && $0.start < realAudioEndSec }
      .map { w -> WordTiming in
        guard w.end > realAudioEndSec else { return w }
        var clamped = w
        clamped.end = realAudioEndSec
        return clamped
      }
    // 1b. CUT — seam ngram dedup: if the head of the fresh words repeats the
    // tail of the committed words (jitter let a duplicate slip past the
    // timestamp filter), drop the repeated head (1..5-gram, longest first).
    if !committedWordsInBuffer.isEmpty, !words.isEmpty {
      let tail = committedWordsInBuffer.suffix(5).map { trimmed($0).lowercased() }
      for n in stride(from: min(5, tail.count, words.count), through: 1, by: -1) {
        let committedTail = tail.suffix(n).joined(separator: " ")
        let freshHead = words.prefix(n).map { trimmed($0).lowercased() }
          .joined(separator: " ")
        if committedTail == freshHead {
          words.removeFirst(n)
          break
        }
      }
    }

    // 2. FLUSH — LocalAgreement-2: commit the longest common word prefix of
    // this hypothesis and the previous cycle's.
    var commitCount = 0
    while commitCount < words.count, commitCount < previousHypothesisWords.count,
      trimmed(words[commitCount]) == trimmed(previousHypothesisWords[commitCount])
    {
      commitCount += 1
    }

    // 2b. FORCE-COMMIT — the deadlock breaker (measured 2026-07-04 on an 85s
    // clip): if agreement stalls (e.g. an unstable hypothesis alternating
    // between cycles) nothing commits → nothing trims → the window freezes
    // while real audio grows past the 30s Whisper window and the ENDING is
    // never decoded at all. When the buffer breaches the hard bound, commit
    // the oldest unagreed words (they have survived in the window across many
    // cycles) up to the retention line so the trim below can advance.
    let realBufferEnd = min(
      max(allWords.last?.end ?? bufferStartSec, bufferStartSec), realAudioEndSec)
    if realBufferEnd - bufferStartSec > maxUnconfirmedWindowSec {
      let forceLine = realBufferEnd - minRetainedBufferSec
      while commitCount < words.count, words[commitCount].end <= forceLine {
        commitCount += 1
      }
    }

    // Retain the uncommitted remainder for the benchmark's release-only arm
    // (set before the commitCount>0 guard, mirroring the segment path).
    retainedUnconfirmedSegments = words[commitCount...].map {
      BenchmarkSegment(text: trimmed($0), start: $0.start, end: $0.end)
    }
    previousHypothesisWords = Array(words[commitCount...])

    if commitCount > 0 {
      for word in words[0..<commitCount] {
        confirmedText = appendText(confirmedText, trimmed(word))
      }
      committedWordsInBuffer.append(contentsOf: words[0..<commitCount])
      // Monotonic guard: never move the confirmed second backwards.
      lastConfirmedSec = max(lastConfirmedSec, words[commitCount - 1].end)
    }

    // 3. TRIM — advance the buffer origin at a committed sentence boundary
    // once the buffer is long (UFAL sentence-mode trimming); force-trim at a
    // committed word if agreement kept committing but no sentence ended before
    // the hard window bound. Two hard constraints beyond the UFAL default,
    // both measured 2026-07-04 on real audio:
    //   - RETENTION: the boundary must keep >= `minRetainedBufferSec` of
    //     audio in the window so the next decode still opens on recent
    //     committed SPEECH, never cold on a pause (the prompt+pause-open
    //     window EOTs into empty output — whisper.cpp streaming keeps audio
    //     context at the window start for the same reason).
    //   - AUDIO CLAMP: candidate boundaries must lie inside the REAL buffered
    //     audio. The decoder hallucinates word timestamps into the silence
    //     PADDING of the 30s window (a word stamped at 99s on an 85s clip);
    //     trimming past real audio empties every later decode and loses the
    //     tail.
    let bufferEnd = realBufferEnd
    if bufferEnd - bufferStartSec > bufferTrimSec {
      let latestAllowed = bufferEnd - minRetainedBufferSec
      let sentenceEnders: Set<Character> = [".", "?", "!"]
      let boundary = committedWordsInBuffer.last(where: { w in
        guard w.end <= latestAllowed, let last = trimmed(w).last else { return false }
        return sentenceEnders.contains(last)
      })?.end
      if let boundary {
        trimBuffer(at: boundary, trimmedWord: trimmed)
      } else if bufferEnd - bufferStartSec > maxUnconfirmedWindowSec,
        let lastCommitted = committedWordsInBuffer.last(where: { $0.end <= latestAllowed })
      {
        trimBuffer(at: lastCommitted.end, trimmedWord: trimmed)
      }
    }
  }

  /// Move the buffer origin to `boundary`: committed words before it scroll
  /// out (their text becomes conditioning-prompt material).
  private func trimBuffer(at boundary: Float, trimmedWord: (WordTiming) -> String) {
    guard boundary > bufferStartSec else { return }
    for word in committedWordsInBuffer where word.end <= boundary {
      scrolledOutText = appendText(scrolledOutText, trimmedWord(word))
    }
    committedWordsInBuffer.removeAll { $0.end <= boundary }
    bufferStartSec = boundary
  }

  private func joinedSegmentText(_ results: [TranscriptionResult]) -> String {
    results.map(\.text)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Append a fragment to an accumulating transcript with a single separating
  /// space, trimming so we never double-space or leave a leading space.
  private func appendText(_ base: String, _ fragment: String) -> String {
    let f = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !f.isEmpty else { return base }
    let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
    return b.isEmpty ? f : b + " " + f
  }

  /// Bounded conditioning prompt: the last ~200 characters of confirmed text,
  /// trimmed forward to a word boundary so we never feed a partial word.
  /// Mirrors UFAL whisper_streaming `OnlineASRProcessor.prompt()` (200-char
  /// suffix of committed text). ~200 chars ≈ 50 tokens, well inside Whisper's
  /// 224-token prompt budget.
  package static func promptSuffix(of text: String, maxChars: Int = 200) -> String {
    guard text.count > maxChars else { return text }
    let tail = text.suffix(maxChars)
    // Drop the leading partial word (everything up to the first space).
    guard let firstSpace = tail.firstIndex(of: " ") else { return String(tail) }
    return String(tail[tail.index(after: firstSpace)...])
      .trimmingCharacters(in: .whitespaces)
  }

  private func streamingResult(
    text: String, samplesCovered: Int, tailDecodeMs: Int
  ) -> IncrementalResult {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return IncrementalResult(
      text: trimmed.isEmpty ? nil : trimmed,
      samplesCovered: samplesCovered, decodeCount: decodeCount,
      totalDecodeTimeMs: totalDecodeTimeMs,
      accepted: !trimmed.isEmpty, mode: "streaming",
      strategy: "streaming", tailDecodeMs: tailDecodeMs)
  }
}
