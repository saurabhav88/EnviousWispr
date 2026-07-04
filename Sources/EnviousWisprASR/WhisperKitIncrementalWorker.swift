import EnviousWisprCore
import Foundation
@preconcurrency import WhisperKit

// FIXME(#827): founder/upstream action needed. WhisperKit must expose decoder
// progress callbacks for incremental and tail transcribe calls before this
// worker can add signal-based wedge recovery without wall-clock timeouts.

package struct IncrementalResult: Sendable {
  package let text: String?
  package let samplesCovered: Int
  package let decodeCount: Int
  package let totalDecodeTimeMs: Int  // periphery:ignore - telemetry field, populated for diagnostics
  package let accepted: Bool
  package let mode: String
  package let strategy: String
  package let tailDecodeMs: Int
}

/// Narrow seam over WhisperKit's transcribe entry point, mirroring
/// `WhisperKitBackendDriving`. Lets `WhisperKitIncrementalWorker` be
/// characterization-tested with a fake decoder instead of a loaded model.
package protocol WhisperKitTranscribing: Sendable {
  func transcribe(audioArray: [Float], decodeOptions: DecodingOptions?) async throws
    -> [TranscriptionResult]
  /// Tokenize text into decoder token IDs for `DecodingOptions.promptTokens`
  /// (prior-text conditioning / `condition_on_previous_text`). Returns `[]` if the
  /// tokenizer is not loaded. Lets the streaming session feed the confirmed prefix
  /// as context on each decode so the model does not hallucinate a trailing
  /// "thank you" on a breath tail (#1276 investigation: decoding blind = the cause).
  func encodeText(_ text: String) -> [Int]
}

// Retroactive @unchecked Sendable: WhisperKit (upstream, @preconcurrency-imported)
// has mutable stored properties so it cannot auto-synthesize Sendable, but every
// caller of the shared instance in this package already goes through actor
// isolation (WhisperKitBackend) or the drain gate (`readyKitAfterWarmupDrain`)
// that serializes access — the same safety argument the rest of this file
// already relies on when passing `WhisperKit` across actor boundaries under
// `@preconcurrency import WhisperKit`.
extension WhisperKit: @retroactive @unchecked Sendable {}

extension WhisperKit: WhisperKitTranscribing {
  // Explicit wrapper: WhisperKit's real `transcribe(audioArray:decodeOptions:callback:segmentCallback:)`
  // has two additional defaulted parameters, which structural witness matching
  // does not bridge automatically. Forward to it explicitly.
  package func transcribe(audioArray: [Float], decodeOptions: DecodingOptions?) async throws
    -> [TranscriptionResult]
  {
    try await self.transcribe(
      audioArray: audioArray, decodeOptions: decodeOptions, callback: nil, segmentCallback: nil)
  }

  package func encodeText(_ text: String) -> [Int] {
    // Leading space matters: OpenAI's reference transcribe.py tokenizes the
    // conditioning prompt as `" " + prompt.strip()` so the tokens land on the
    // space-prefixed BPE distribution the decoder was trained on (verified in
    // the prefill trace: words tokenize as `Ġ`-prefixed IDs with this form).
    tokenizer?.encode(text: " " + text.trimmingCharacters(in: .whitespaces)) ?? []
  }
}

/// Periodically transcribes the growing audio buffer during recording.
/// Purely an internal latency optimization — no UI, no streaming model.
///
/// Adaptive strategy:
/// - Short recordings (<30s): re-transcribe full buffer each cycle (highest quality)
/// - Long recordings (>30s): use clipTimestamps to only decode new audio (efficient)
/// - On finalize: async tail decode covers speech after the last worker result
package actor WhisperKitIncrementalWorker: WhisperKitIncrementalSession {
  private let whisperKit: any WhisperKitTranscribing
  private let baseDecodingOptions: DecodingOptions
  private let cadence: Duration
  private let longRecordingThreshold: Int = 16000 * 30

  private var accumulatedText: String = ""
  private var lastFullResult: String?
  private var lastResultSampleCount: Int = 0
  private var lastClipSeconds: Float = 0
  private var decodeCount: Int = 0
  private var totalDecodeTimeMs: Int = 0

  private var running = false
  private var loopTask: Task<Void, Never>?

  /// Test-only observability seam (Codex cloud review, #1275): the real
  /// signal tests need is "has the loop actually recorded N decodes," not a
  /// proxy for it. `decodeCount` only increments AFTER `runLoop` resumes from
  /// its `await whisperKit.transcribe(...)` call and stores the result — so
  /// polling this directly (unlike waiting on the fake decoder being merely
  /// CALLED) is race-free: it reflects worker state, not decoder-call timing
  /// that has no guaranteed ordering against it across the actor boundary.
  package var currentDecodeCount: Int { decodeCount }

  /// `cadence` defaults to the shipped 3s cycle; tests inject a near-zero
  /// value so the run loop's boundary behavior can be characterized without
  /// waiting on real wall-clock time (#1275).
  package init(
    whisperKit: any WhisperKitTranscribing, decodingOptions: DecodingOptions,
    cadence: Duration = .seconds(3)
  ) {
    self.whisperKit = whisperKit
    self.baseDecodingOptions = decodingOptions
    self.cadence = cadence
  }

  /// Selects the finalize candidate text. Long-mode prefers `accumulatedText`
  /// (the clipped incremental accumulation) but falls back to `lastFullResult`
  /// when the recording only crossed the 30s boundary between the worker's
  /// last short-mode decode and finalize — `lastFullResult` still covers
  /// exactly `lastResultSampleCount` samples and the tail decode covers the
  /// remainder, so it is a valid candidate, not a discard signal (#1275).
  package static func selectCandidateText(
    isLong: Bool,
    accumulatedText: String,
    lastFullResult: String?
  ) -> String? {
    guard isLong else { return lastFullResult }
    let trimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? lastFullResult : accumulatedText
  }

  /// Joins the worker's candidate text with the tail decode's text, trimming
  /// a duplicated overlap at the seam when the tail's start literally
  /// repeats the end of the candidate — the deliberate 1.0s audio overlap
  /// (`overlapStartSeconds` above) re-decodes the same speech, and WhisperKit
  /// can emit a partial-token continuation split across both decodes (e.g.
  /// candidate ends "...lingerie outside?", tail starts "gerie outside?").
  ///
  /// Case-insensitive longest-common-affix between the last `maxWindow`
  /// characters of `candidate` and the first `maxWindow` characters of
  /// `tail`, bounded to a span plausibly produced by the ~1s audio overlap.
  /// Punctuation and whitespace are compared literally (not stripped) — a
  /// diverging trailing punctuation mark only prevents a match, it never
  /// causes an incorrect trim. Trims ONLY from `tail`'s prefix; `candidate`
  /// is never modified, and no text is removed without a positive seam
  /// match (no match → today's naive `candidate + " " + tail` join).
  ///
  /// Known residual risk (accepted, #1275 §7): a genuine word repeated by
  /// the speaker exactly at the seam (e.g. "...standing outside outside in
  /// the rain") is indistinguishable from acoustic-overlap duplication from
  /// text alone, so this can wrongly trim one copy. The trimmer anchors
  /// strictly on the seam (candidate suffix vs tail prefix), never a global
  /// dedup, to keep this risk local to the boundary.
  ///
  /// `minOverlap` (Codex r1 P2): a 1-3 character coincidental match (e.g.
  /// candidate "I am" / tail "amazing today" sharing "am") is far more
  /// likely to be an unrelated word boundary than genuine acoustic overlap
  /// — trimming on it corrupts normal continuations ("I am azing today").
  /// 6 characters comfortably covers the shortest confirmed real overlap
  /// case ("gerie " — 6 chars, from the founder's `lingerie`/`gerie` repro)
  /// while excluding short coincidences.
  ///
  /// KNOWN REGRESSION, not fixed by this trimmer, shipped intentionally as
  /// documented residual risk (#1275, Live UAT 2026-07-02): this only
  /// catches a duplicate anchored at the LITERAL seam — candidate's exact
  /// suffix matching tail's exact prefix. It does NOT catch a duplicate
  /// where the tail's decode window re-transcribes a phrase from EARLIER in
  /// candidate (not candidate's trailing edge). Live-repro: dictating "Can
  /// you double check the numbers in the spreadsheet before I send it to
  /// the client" produced candidate "...the numbers in the spreadsheet?"
  /// and tail "e numbers in the spreadsheet before..." — the duplicated
  /// phrase "the numbers in the spreadsheet" sits mid-candidate, not at its
  /// suffix, so no seam match exists for this function to find; the raw
  /// ASR text ships with the phrase duplicated (LLM Polish sometimes, not
  /// always, cleans it up downstream — do not rely on that). Root cause is
  /// structural: this function's suffix/prefix seam-matching approach
  /// cannot express "the tail re-covers audio already transcribed earlier
  /// in candidate, not just at the boundary." Fixing this properly means
  /// replacing the whole re-transcribe-and-textually-stitch design with
  /// WhisperKit's official streaming mechanism (confirmed-vs-hypothesis
  /// text via LocalAgreement, `AudioStreamTranscriber`), which never emits
  /// two independent text spans that need post-hoc joining in the first
  /// place — see #1276 (filed as this bug's structural fix, not a patch).
  package static func joinWithOverlapTrim(_ candidate: String, _ tail: String) -> String {
    guard !tail.isEmpty else { return candidate }
    guard !candidate.isEmpty else { return tail }

    let maxWindow = 80
    let minOverlap = 6
    let candidateWindow = Array(candidate.suffix(maxWindow)).map { Character($0.lowercased()) }
    let tailWindow = Array(tail.prefix(maxWindow)).map { Character($0.lowercased()) }

    var overlapLength = 0
    let maxK = min(candidateWindow.count, tailWindow.count)
    if maxK >= minOverlap {
      for k in stride(from: maxK, through: minOverlap, by: -1) {
        if candidateWindow.suffix(k).elementsEqual(tailWindow.prefix(k)) {
          overlapLength = k
          break
        }
      }
    }

    guard overlapLength > 0 else {
      return candidate + " " + tail
    }

    let trimStart = tail.index(tail.startIndex, offsetBy: overlapLength)
    let trimmedTail = String(tail[trimStart...]).trimmingCharacters(in: .whitespaces)
    guard !trimmedTail.isEmpty else { return candidate }
    return candidate + " " + trimmedTail
  }

  package func start(
    audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)
  ) {
    running = true
    accumulatedText = ""
    lastFullResult = nil
    lastResultSampleCount = 0
    lastClipSeconds = 0
    decodeCount = 0
    totalDecodeTimeMs = 0

    loopTask = Task { [weak self] in
      guard let self else { return }
      await self.runLoop(audioSamplesProvider: audioSamplesProvider)
    }
  }

  // periphery:ignore:parameters speechSegments - kept for API compatibility; energy-based gate replaced VAD segment check
  package func finalize(
    finalSamples: [Float],
    speechSegments: [SpeechSegment]
  ) async -> IncrementalResult {
    running = false
    loopTask?.cancel()
    loopTask = nil

    let isLong = finalSamples.count > longRecordingThreshold

    guard decodeCount > 0 else {
      return IncrementalResult(
        text: nil, samplesCovered: 0, decodeCount: 0,
        totalDecodeTimeMs: 0, accepted: false,
        mode: isLong ? "clipped" : "full",
        strategy: "no_worker", tailDecodeMs: 0
      )
    }

    let candidateText = Self.selectCandidateText(
      isLong: isLong, accumulatedText: accumulatedText, lastFullResult: lastFullResult
    )
    let hasText =
      candidateText != nil
      && !candidateText!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    guard hasText else {
      return IncrementalResult(
        text: nil, samplesCovered: lastResultSampleCount, decodeCount: decodeCount,
        totalDecodeTimeMs: totalDecodeTimeMs, accepted: false,
        mode: isLong ? "clipped" : "full",
        strategy: "no_worker", tailDecodeMs: 0
      )
    }

    let baseMode = isLong ? "clipped" : "full"

    // Gate tail decode on uncovered sample count + energy, not VAD segments.
    // In XPC mode, speechSegments is always [] (silenceDetector is nil in pipeline's
    // XPC monitorVAD branch), so the old tailHasSpeech guard always returned false
    // and the tail decode was permanently skipped — losing up to 3s of audio.
    let uncoveredSamples = finalSamples.count - lastResultSampleCount
    let needsTailDecode: Bool
    if uncoveredSamples > 1600 {  // >100ms uncovered
      // Quick RMS check — is there actual audio in the tail, not just silence?
      let tailStart = max(0, lastResultSampleCount)
      let tailSlice = Array(finalSamples[tailStart..<finalSamples.count])
      let rms =
        tailSlice.isEmpty
        ? Float(0) : sqrt(tailSlice.reduce(Float(0)) { $0 + $1 * $1 } / Float(tailSlice.count))
      needsTailDecode = rms > 0.001  // above noise floor
    } else {
      needsTailDecode = false
    }

    if !needsTailDecode {
      return IncrementalResult(
        text: candidateText, samplesCovered: lastResultSampleCount,
        decodeCount: decodeCount, totalDecodeTimeMs: totalDecodeTimeMs,
        accepted: true, mode: baseMode,
        strategy: "worker_only", tailDecodeMs: 0
      )
    }

    // Tail has speech — decode with standard silence padding.
    let paddedSamples = WhisperKitBackend.padAudioWithSilence(finalSamples)

    let tailStart = CFAbsoluteTimeGetCurrent()
    do {
      let overlapStartSeconds = max(0, Float(lastResultSampleCount) / 16000.0 - 1.0)
      let tailDurationSeconds = Float(finalSamples.count - lastResultSampleCount) / 16000.0
      var opts = baseDecodingOptions
      opts.clipTimestamps = [overlapStartSeconds]
      opts.windowClipTime = 0

      // Do NOT pass promptTokens for the tail decode. When the worker's last
      // text ends a sentence (e.g., "finalize the vendor contract"), prompt
      // tokens bias the decoder to emit end-of-text instead of transcribing
      // the remaining short fragment (e.g., "by Friday"). This was the root
      // cause of #216: tail decode returned empty despite speech being present.

      // TODO(#827): watchdog needs WhisperKit decoder-step progress during tail
      // decode; cancellation depends on this await returning.
      let results = try await whisperKit.transcribe(audioArray: paddedSamples, decodeOptions: opts)
      let tailText = results.map(\.text)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)

      let tailMs = Int((CFAbsoluteTimeGetCurrent() - tailStart) * 1000)

      // Implied 30s-window count spanned by this decode's clip range. WhisperKit
      // always encodes a fixed 30s window per pass — a value >1 here means the
      // clip range exceeds one window (stale worker, large uncovered tail).
      // Measurement only (#1275 item C): never silently clamp the clip start,
      // since that would drop uncovered audio unless the worker text already
      // represents it.
      let clipSpanSeconds = Float(paddedSamples.count) / 16000.0 - overlapStartSeconds
      let impliedWindowCount = max(1, Int(ceil(Double(clipSpanSeconds) / 30.0)))

      await AppLogger.shared.log(
        "TAIL_DIAG: workerText=[\(candidateText?.suffix(60) ?? "nil")] "
          + "tailText=[\(tailText.suffix(60))] "
          + "overlapStart=\(String(format: "%.1f", overlapStartSeconds))s "
          + "uncoveredDuration=\(String(format: "%.1f", tailDurationSeconds))s "
          + "tailDecodeMs=\(tailMs) "
          + "impliedWindows=\(impliedWindowCount)",
        level: .info, category: "WhisperKitWorker"
      )

      if !tailText.isEmpty {
        let finalText = Self.joinWithOverlapTrim(candidateText!, tailText)
        return IncrementalResult(
          text: finalText, samplesCovered: finalSamples.count,
          decodeCount: decodeCount, totalDecodeTimeMs: totalDecodeTimeMs,
          accepted: true, mode: baseMode + "+tail",
          strategy: "worker+tail", tailDecodeMs: tailMs
        )
      }

      // Tail decode returned empty despite speech evidence (RMS > 0.001).
      // Do NOT silently accept the truncated worker result. Signal batch
      // fallback so the pipeline re-transcribes the full audio.
      await AppLogger.shared.log(
        "TAIL_DIAG: empty tail despite speech evidence, triggering batch fallback "
          + "(uncovered=\(String(format: "%.1f", tailDurationSeconds))s)",
        level: .info, category: "WhisperKitWorker"
      )
      return IncrementalResult(
        text: nil, samplesCovered: lastResultSampleCount,
        decodeCount: decodeCount, totalDecodeTimeMs: totalDecodeTimeMs,
        accepted: false, mode: baseMode,
        strategy: "tail_empty_fallback", tailDecodeMs: tailMs
      )
    } catch {
      let tailMs = Int((CFAbsoluteTimeGetCurrent() - tailStart) * 1000)
      return IncrementalResult(
        text: nil, samplesCovered: lastResultSampleCount,
        decodeCount: decodeCount, totalDecodeTimeMs: totalDecodeTimeMs,
        accepted: false, mode: baseMode,
        strategy: "batch_fallback", tailDecodeMs: tailMs
      )
    }
  }

  package func cancel() {
    running = false
    loopTask?.cancel()
    loopTask = nil
  }

  // MARK: - Private

  private func runLoop(
    audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)
  ) async {
    while running && !Task.isCancelled {
      try? await Task.sleep(for: cadence)
      guard running && !Task.isCancelled else { break }

      let snapshot = await audioSamplesProvider()
      guard snapshot.count >= 16000 else { continue }

      let isLongRecording = snapshot.count > longRecordingThreshold
      let decodeStart = CFAbsoluteTimeGetCurrent()

      do {
        if isLongRecording {
          var opts = baseDecodingOptions
          opts.clipTimestamps = [lastClipSeconds]
          // TODO(#827): watchdog needs decoder-step progress for clipped
          // incremental decodes; accepted-byte counters only move after this
          // await returns.
          let results = try await whisperKit.transcribe(
            audioArray: snapshot.samples, decodeOptions: opts
          )
          let newText = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

          if !newText.isEmpty {
            if let lastSeg = results.last?.segments.last {
              lastClipSeconds = lastSeg.end
            }
            if accumulatedText.isEmpty {
              accumulatedText = newText
            } else {
              accumulatedText = accumulatedText + " " + newText
            }
            lastResultSampleCount = snapshot.count
          }
        } else {
          // TODO(#827): watchdog needs decoder-step progress for full-buffer
          // incremental decodes; accepted-byte counters only move after this
          // await returns.
          let results = try await whisperKit.transcribe(
            audioArray: snapshot.samples, decodeOptions: baseDecodingOptions
          )
          let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

          if !text.isEmpty {
            lastFullResult = text
            lastResultSampleCount = snapshot.count
          }
        }

        decodeCount += 1
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - decodeStart) * 1000)
        totalDecodeTimeMs += elapsedMs

        await AppLogger.shared.log(
          "WhisperKit incremental decode #\(decodeCount): \(elapsedMs)ms, "
            + "mode=\(isLongRecording ? "clipped" : "full"), " + "samples=\(snapshot.count)",
          level: .info, category: "WhisperKitWorker"
        )
      } catch {
        if !Task.isCancelled {
          await AppLogger.shared.log(
            "WhisperKit incremental decode failed: \(error.localizedDescription)",
            level: .info, category: "WhisperKitWorker"
          )
        }
      }
    }
  }
}
