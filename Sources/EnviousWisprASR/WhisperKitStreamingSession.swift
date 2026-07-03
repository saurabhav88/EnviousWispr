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
// Algorithm (lifted from WhisperKit's `AudioStreamTranscriber` segment-holdback
// loop, driven by OUR capture — whisperkit-research.md
// FACT: audiostreamtranscriber-actual-mechanism):
//   - Per cycle: pull the adapter-owned lossless `streamingPCM` via the provider;
//     gate on >= 1s of new audio; decode the window from `lastConfirmedSec` to the
//     end with `clipTimestamps = [lastConfirmedSec]` + `chunkingStrategy: .none`
//     (NEVER `.vad` — see F2 below). `language` is the picked code (locked), so
//     the decoder prefills the known language token: no LID, no garble.
//   - Confirmation: if `segments.count > requiredSegmentsForConfirmation` (N=2),
//     freeze the prefix `count-N` segments into confirmed text and advance
//     `lastConfirmedSec` to the last confirmed segment's end. The trailing N stay
//     unconfirmed and are re-decoded next cycle.
//   - Unconfirmed-window bound: if confirmation stalls (long pause, low
//     confidence) and `end - lastConfirmedSec` exceeds `maxUnconfirmedWindowSec`
//     (~25s), force-confirm the oldest unconfirmed segment(s) so the decode window
//     stays under one 30s WhisperKit window (avoids the `.none`-over-30s cost
//     cliff; Codex r1 PARTIAL).
//   - `finalize`: the adapter drains its feed tasks FIRST (so `streamingPCM` is
//     complete), then this session pulls the retained provider one more time and
//     runs ONE bounded tail decode over `[lastConfirmedSec .. end]`. Its output IS
//     the transcript (authoritative), NOT a best-effort rescue. The
//     `finalSamples` parameter is intentionally IGNORED (single-coordinate design,
//     §3.2): flushing over `finalSamples` would reopen the pre-roll coordinate bug
//     because `lastConfirmedSec` was learned from `streamingPCM`, not `finalSamples`.
//
// F2: `.none` + clip-seek slices only `audioArray[seek..<seek+window]`, bounded;
// `.vad` re-chunks the whole growing buffer every cycle (O(n^2)), which wedged the
// 10-min benchmark. The base decode options force `.none`; the session never
// re-derives options per cycle (which would flip to `.vad` above 30s).

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

  /// Minimum voiced tail (seconds) below which the flush SKIPS the tail decode —
  /// decoding near-silence invites the YouTube-corpus "Thank you" hallucination
  /// (whisperkit-research.md FACT: whisper-yt-corpus-artifact). The confirmed
  /// text is already complete when the uncovered tail is this short.
  private let minVoicedTailSec: Float = 0.4

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
  package init(
    whisperKit: any WhisperKitTranscribing,
    decodingOptions: DecodingOptions,
    requiredSegmentsForConfirmation: Int = 2,
    cadence: Duration = .seconds(1)
  ) {
    self.whisperKit = whisperKit
    self.baseDecodingOptions = decodingOptions
    self.requiredSegmentsForConfirmation = max(1, requiredSegmentsForConfirmation)
    self.cadence = cadence
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
    let flushConfirmedSec = lastConfirmedSec
    let durationSec = Float(count) / 16_000.0
    let uncoveredTailSec = durationSec - flushConfirmedSec

    // Tail gate (energy-aware, mirrors `WhisperKitIncrementalWorker`'s tail-decode
    // gate): skip the flush decode when the uncovered tail is too short OR too
    // quiet. A near-silence tail decoded anyway invites the YouTube-corpus
    // "Thank you" hallucination, and when the confirmed prefix already covers all
    // the speech it IS the complete transcript — accepting it (rather than forcing
    // a needless full re-batch) preserves the streaming speed win.
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

  package func cancel() {
    running = false
    finished = true
    loopTask?.cancel()
    loopTask = nil
    audioSamplesProvider = nil
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
      opts.clipTimestamps = [lastConfirmedSec]
      opts.windowClipTime = 0
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
    guard confirmCount > 0 else { return }

    for segment in segments[0..<confirmCount] {
      confirmedText = appendText(confirmedText, segment.text)
    }
    // Monotonic guard: never move the confirmed second backwards.
    lastConfirmedSec = max(lastConfirmedSec, segments[confirmCount - 1].end)
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
