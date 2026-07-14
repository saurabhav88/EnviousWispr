import EnviousWisprCore
import Foundation
@preconcurrency import WhisperKit

// MARK: - Tail-finalization benchmark harness (#1276 PR-2, rulebook §5)
//
// A benchmark-ONLY facade over the shipped `WhisperKitStreamingSession`. It lives
// in this module (not the standalone `scripts/eval/tail_runner` CLI) for one
// reason: the streaming session, its `BenchmarkSnapshot` seam, and the
// `WhisperKitTranscribing` protocol are all `package`-scoped, so only same-package
// code can drive them. This facade exposes the NARROWEST possible `public`
// surface — load a model, replay one clip through all four candidate finishes,
// and a determinism (replay-fidelity, §5.3) check — while every heart-path type
// stays package-internal. The shipped app never calls any of this.
//
// The four candidate finishes (arms), each run from ONE frozen certified
// checkpoint so the comparison is paired (rulebook §1):
//   S1 release-only          — emit confirmed prefix + the retained held-back
//                              hypothesis, deduped at the seam. NO new inference.
//   S2 bounded-cleanup        — one silence-TRIMMED decode of the uncovered voiced
//                              tail (if any), then release. (Contrast S3: pads.)
//   S3 incumbent (shipped)    — the real `finalize()` padded tail decode, run
//                              verbatim on a second identical feed (zero reimpl).
//   S4 full re-decode         — a clean batch decode of the whole clip.
// periphery:ignore:all - benchmark facade, only referenced by the external tail_runner CLI.

/// One arm's emitted final text for one clip. Encodes to the `report.py`
/// `ARM_SCHEMA` (snake_case) so the Python scorecard consumes it directly.
public struct TailArmOutput: Codable, Sendable {
  public let id: String
  public let arm: String
  public let emitted: String
  public let word_timestamps: [Float]?
  public let fallback_fired: Bool
  public let latency_ms: Double
}

/// Replay-fidelity outcome for one clip (§5.3): did two independent feeds of the
/// identical audio freeze the identical certified checkpoint?
public struct TailFidelityOutcome: Codable, Sendable {
  public let id: String
  public let matched: Bool
  public let detail: String
}

/// Opaque loaded-model handle. Wraps the `package` WhisperKit seam + the base
/// decode options so the CLI never touches package types.
public final class TailBenchmarkModel: @unchecked Sendable {
  let kit: any WhisperKitTranscribing
  let baseOptions: DecodingOptions
  let sampleRate: Int = 16_000
  /// A/B switch: run the streaming decodes with prior-text conditioning on.
  let conditionOnPriorText: Bool
  /// A/B switch: confirm via word-level LocalAgreement-2 instead of segment lag.
  let localAgreement: Bool

  init(
    kit: any WhisperKitTranscribing, baseOptions: DecodingOptions,
    conditionOnPriorText: Bool = false, localAgreement: Bool = false
  ) {
    self.kit = kit
    self.baseOptions = baseOptions
    self.conditionOnPriorText = conditionOnPriorText
    self.localAgreement = localAgreement
  }
}

public enum TailBenchmarkHarness {
  /// Load the real on-disk WhisperKit model and build the locked-English decode
  /// options that mirror `WhisperKitBackend.makeDecodeOptions(sampleCount: 0)`
  /// (the streaming construction path). `language` is locked (no LID) exactly as
  /// the "Live transcription" toggle's ON path uses it.
  public static func loadModel(
    modelFolder: String, language: String = "en", conditionOnPriorText: Bool = false,
    localAgreement: Bool = false
  ) async throws -> TailBenchmarkModel {
    let config = WhisperKitConfig(modelFolder: modelFolder)
    let kit = try await WhisperKit(config)
    var opts = DecodingOptions()
    opts.language = language
    opts.detectLanguage = false
    opts.wordTimestamps = true
    opts.temperature = 0.0
    opts.temperatureFallbackCount = 3
    opts.temperatureIncrementOnFallback = 0.2
    opts.compressionRatioThreshold = 2.4
    opts.logProbThreshold = -1.0
    opts.noSpeechThreshold = 0.6
    opts.skipSpecialTokens = true
    opts.suppressBlank = true
    opts.usePrefillPrompt = true
    opts.chunkingStrategy = ChunkingStrategy.none
    opts.windowClipTime = 0
    return TailBenchmarkModel(
      kit: kit, baseOptions: opts, conditionOnPriorText: conditionOnPriorText,
      localAgreement: localAgreement)
  }

  // MARK: Feed + capture

  /// Grows a lossless sample buffer in fixed steps, mimicking the adapter-owned
  /// `streamingPCM` the session pulls each cycle. Deterministic by construction:
  /// `arrived` only advances via `advanceTo`, so two feeds of the same clip pull
  /// the same prefixes (backs the §5.3 fidelity gate).
  actor Feeder {
    let all: [Float]
    private var arrived = 0
    init(all: [Float]) { self.all = all }
    func advanceTo(_ n: Int) { arrived = min(all.count, max(arrived, n)) }
    func drain() { arrived = all.count }
    func pull() -> (samples: [Float], count: Int) {
      (Array(all[0..<arrived]), arrived)
    }
  }

  /// Session cadence for benchmark feeds. Small and fixed: determinism comes from
  /// the decode-count GATE below (a signal), never from wall-clock cadence, so a
  /// short cadence just makes the loop poll its provider promptly. `cadenceSeconds`
  /// on the public entry points is retained for API stability but no longer drives
  /// correctness (the race it used to create is gone).
  static let feedCadence: Duration = .milliseconds(30)

  /// Feed `samples` into a freshly-started `session` DETERMINISTICALLY: advance
  /// the provider one 16 000-sample chunk at a time, and advance the NEXT chunk
  /// only once the loop has actually decoded the current one (gate on
  /// `decodeCount`, an observable signal — RULE: prefer-signal-based-detection —
  /// never a fixed sleep). This removes the feed↔loop clock race that made the
  /// confirmed boundary non-reproducible (§5.3). Each 16 000-sample chunk triggers
  /// exactly one loop decode (the `minNewSamplesToDecode` gate); the sub-chunk
  /// remainder never decodes (correct: the live loop leaves that tail to finalize).
  /// Ends with the buffer drained, matching the adapter completing `streamingPCM`
  /// before finalize.
  static func feedDeterministic(
    session: WhisperKitStreamingSession, feeder: Feeder, total: Int
  ) async {
    let step = 16_000
    let fullChunks = total / step
    var i = 1
    while i <= fullChunks {
      await feeder.advanceTo(i * step)
      var guardIters = 0
      while await session.currentDecodeCount < i {
        try? await Task.sleep(for: .milliseconds(5))
        guardIters += 1
        if guardIters > 6000 { break }  // ~30s per chunk safety net (decode threw/stalled)
      }
      i += 1
    }
    await feeder.drain()
  }

  /// Drive one streaming pass over `samples` and return the frozen certified
  /// checkpoint.
  static func driveToSnapshot(
    model: TailBenchmarkModel, samples: [Float],
    cadenceSeconds: Double, stepSamples: Int
  ) async -> BenchmarkSnapshot? {
    let feeder = Feeder(all: samples)
    let session = WhisperKitStreamingSession(
      whisperKit: model.kit, decodingOptions: model.baseOptions, cadence: feedCadence,
      conditionOnPriorText: model.conditionOnPriorText,
      localAgreement: model.localAgreement)
    await session.start(audioSamplesProvider: { await feeder.pull() })
    await feedDeterministic(session: session, feeder: feeder, total: samples.count)
    return await session.benchmarkCaptureAndStop()
  }

  // MARK: Public entry points

  /// Replay one clip through the requested arms from a single frozen checkpoint.
  public static func runClip(
    model: TailBenchmarkModel, id: String, samples: [Float],
    cadenceSeconds: Double = 1.0, stepSamples: Int = 16_000,
    arms: Set<String> = ["S1", "S2", "S3", "S4"]
  ) async -> [TailArmOutput] {
    var out: [TailArmOutput] = []
    guard
      let snap = await driveToSnapshot(
        model: model, samples: samples,
        cadenceSeconds: cadenceSeconds, stepSamples: stepSamples)
    else { return out }

    if arms.contains("S1") { out.append(await armS1(id: id, snap: snap)) }
    if arms.contains("S2") { out.append(await armS2(model: model, id: id, snap: snap)) }
    if arms.contains("S4") { out.append(await armS4(model: model, id: id, snap: snap)) }
    if arms.contains("S5") { out.append(await armS5(model: model, id: id, snap: snap)) }
    // S3 is the REAL shipped finalize on a second identical feed (no reimpl).
    if arms.contains("S3") {
      out.append(
        await armS3(
          model: model, id: id, samples: samples,
          cadenceSeconds: cadenceSeconds, stepSamples: stepSamples))
    }
    return out
  }

  /// §5.3 replay-fidelity: two independent feeds of the identical audio must
  /// freeze the identical checkpoint (payload hash, confirmed prefix, confirmed
  /// second, sample count). Certifies the harness before any arm is scored.
  public static func fidelity(
    model: TailBenchmarkModel, id: String, samples: [Float],
    cadenceSeconds: Double = 1.0, stepSamples: Int = 16_000
  ) async -> TailFidelityOutcome {
    let a = await driveToSnapshot(
      model: model, samples: samples, cadenceSeconds: cadenceSeconds, stepSamples: stepSamples)
    let b = await driveToSnapshot(
      model: model, samples: samples, cadenceSeconds: cadenceSeconds, stepSamples: stepSamples)
    guard let a, let b else {
      return TailFidelityOutcome(id: id, matched: false, detail: "capture returned nil")
    }
    var mismatches: [String] = []
    if a.contentHash != b.contentHash { mismatches.append("payloadHash") }
    if a.sampleCount != b.sampleCount { mismatches.append("sampleCount") }
    if a.confirmedText != b.confirmedText { mismatches.append("confirmedText") }
    if a.lastConfirmedSec != b.lastConfirmedSec { mismatches.append("lastConfirmedSec") }
    return TailFidelityOutcome(
      id: id, matched: mismatches.isEmpty,
      detail: mismatches.isEmpty ? "identical" : "differ: " + mismatches.joined(separator: ","))
  }

  // MARK: Arms

  private static func armS1(id: String, snap: BenchmarkSnapshot) async -> TailArmOutput {
    let start = CFAbsoluteTimeGetCurrent()
    let tail = snap.unconfirmedSegments.map(\.text)
      .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    let emitted = dedupSeam(confirmed: snap.confirmedText, tail: tail)
    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
    return TailArmOutput(
      id: id, arm: "S1", emitted: emitted, word_timestamps: nil,
      fallback_fired: false, latency_ms: ms)
  }

  private static func armS2(model: TailBenchmarkModel, id: String, snap: BenchmarkSnapshot)
    async -> TailArmOutput
  {
    let start = CFAbsoluteTimeGetCurrent()
    let count = snap.sampleCount
    let sr = Float(model.sampleRate)
    let durationSec = Float(count) / sr
    let uncoveredSec = durationSec - snap.lastConfirmedSec
    let tailStartIdx = max(0, min(count, Int(snap.lastConfirmedSec * sr)))
    let tailSlice = tailStartIdx < count ? Array(snap.samples[tailStartIdx..<count]) : []

    // No voiced uncovered tail → the confirmed prefix already is the transcript.
    guard uncoveredSec >= 0.1, rms(tailSlice) > 0.001 else {
      let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
      return TailArmOutput(
        id: id, arm: "S2", emitted: snap.confirmedText, word_timestamps: nil,
        fallback_fired: false, latency_ms: ms)
    }

    // One silence-TRIMMED decode of [lastConfirmedSec .. voiced end]. S2's
    // distinction from S3: trim the trailing silence instead of padding it.
    let voicedLen = trailingVoicedLength(tailSlice)
    let trimmedEnd = tailStartIdx + voicedLen
    let decodeInput = Array(snap.samples[0..<max(tailStartIdx, trimmedEnd)])
    var opts = model.baseOptions
    opts.clipTimestamps = [snap.lastConfirmedSec]
    opts.windowClipTime = 0
    do {
      let results = try await model.kit.transcribe(audioArray: decodeInput, decodeOptions: opts)
      let tailText = joinedText(results)
      let emitted = tailText.isEmpty ? snap.confirmedText : appendText(snap.confirmedText, tailText)
      let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
      return TailArmOutput(
        id: id, arm: "S2", emitted: emitted, word_timestamps: wordEndTimes(results),
        fallback_fired: tailText.isEmpty, latency_ms: ms)
    } catch {
      let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
      return TailArmOutput(
        id: id, arm: "S2", emitted: snap.confirmedText, word_timestamps: nil,
        fallback_fired: true, latency_ms: ms)
    }
  }

  private static func armS3(
    model: TailBenchmarkModel, id: String, samples: [Float],
    cadenceSeconds: Double, stepSamples: Int
  ) async -> TailArmOutput {
    // The REAL shipped finalize, run on a second identical (deterministic) feed.
    // Zero reimpl of the incumbent → the scorecard measures exactly what ships.
    let feeder = Feeder(all: samples)
    let session = WhisperKitStreamingSession(
      whisperKit: model.kit, decodingOptions: model.baseOptions, cadence: feedCadence,
      conditionOnPriorText: model.conditionOnPriorText,
      localAgreement: model.localAgreement)
    await session.start(audioSamplesProvider: { await feeder.pull() })
    await feedDeterministic(session: session, feeder: feeder, total: samples.count)

    let start = CFAbsoluteTimeGetCurrent()
    let result = await session.finalize(finalSamples: [], speechSegments: [])
    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
    return TailArmOutput(
      id: id, arm: "S3", emitted: result.text ?? "", word_timestamps: nil,
      fallback_fired: !result.accepted, latency_ms: ms)
  }

  private static func armS4(model: TailBenchmarkModel, id: String, snap: BenchmarkSnapshot)
    async -> TailArmOutput
  {
    let start = CFAbsoluteTimeGetCurrent()
    var opts = model.baseOptions
    opts.clipTimestamps = []
    // Mirror the clean batch path: VAD-chunk clips over 30s to avoid the
    // hallucinated-repetition cliff a whole-buffer `.none` decode hits.
    let thirtySec = model.sampleRate * 30
    opts.chunkingStrategy = snap.sampleCount > thirtySec ? .vad : ChunkingStrategy.none
    let padded = WhisperKitBackend.padAudioWithSilence(snap.samples)
    do {
      let results = try await model.kit.transcribe(audioArray: padded, decodeOptions: opts)
      let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
      return TailArmOutput(
        id: id, arm: "S4", emitted: joinedText(results),
        word_timestamps: wordEndTimes(results), fallback_fired: false, latency_ms: ms)
    } catch {
      let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
      return TailArmOutput(
        id: id, arm: "S4", emitted: "", word_timestamps: nil,
        fallback_fired: true, latency_ms: ms)
    }
  }

  /// Arm S5 — UFAL streaming + ONE bounded final decode of the live buffer at
  /// stop (the missing-final-chunk closer). NOT S4: it never re-decodes scrolled
  /// -out audio; the window is the same bounded `[bufferStartSec .. end]` (≤~15s
  /// typical) the loop already decodes every cycle, with the same scrolled-out
  /// prompt, run once more over the now-complete audio. Text before the buffer
  /// (`scrolledOutText`) is kept verbatim; the decode's output replaces the
  /// in-buffer committed + retained hypothesis (single decode, no stitching).
  static func armS5(model: TailBenchmarkModel, id: String, snap: BenchmarkSnapshot)
    async -> TailArmOutput
  {
    let start = CFAbsoluteTimeGetCurrent()
    var opts = model.baseOptions
    opts.clipTimestamps = [snap.bufferStartSec]
    opts.windowClipTime = 0
    opts.promptTokens = nil
    if model.conditionOnPriorText, !snap.scrolledOutText.isEmpty {
      opts.promptTokens = model.kit.encodeText(
        WhisperKitStreamingSession.promptSuffix(of: snap.scrolledOutText))
    }
    // Same trailing-silence pad the shipped flush applies for last-word context.
    let padded = WhisperKitBackend.padAudioWithSilence(snap.samples)
    do {
      let results = try await model.kit.transcribe(audioArray: padded, decodeOptions: opts)
      let bufferText = joinedText(results)
      // Fallback on an empty decode: plain release (confirmedText already
      // CONTAINS the scrolled-out prefix — never re-prepend it).
      let releaseTail = snap.unconfirmedSegments.map(\.text)
        .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      let emitted =
        bufferText.isEmpty
        ? dedupSeam(confirmed: snap.confirmedText, tail: releaseTail)
        : appendText(snap.scrolledOutText, bufferText)
      let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
      return TailArmOutput(
        id: id, arm: "S5", emitted: emitted,
        word_timestamps: wordEndTimes(results),
        fallback_fired: bufferText.isEmpty, latency_ms: ms)
    } catch {
      let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
      let releaseTail = snap.unconfirmedSegments.map(\.text)
        .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      return TailArmOutput(
        id: id, arm: "S5", emitted: dedupSeam(confirmed: snap.confirmedText, tail: releaseTail),
        word_timestamps: nil, fallback_fired: true, latency_ms: ms)
    }
  }

  // MARK: Text + audio utilities

  /// Join confirmed + released tail, removing a duplicated k-word phrase at the
  /// seam (the release-only arm's own dedup — the LocalAgreement overlap the
  /// stream would otherwise double-print).
  static func dedupSeam(confirmed: String, tail: String, kMax: Int = 6) -> String {
    let c = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
    let t = tail.trimmingCharacters(in: .whitespacesAndNewlines)
    if c.isEmpty { return t }
    if t.isEmpty { return c }
    let cw = c.split(separator: " ").map(String.init)
    let tw = t.split(separator: " ").map(String.init)
    let maxK = min(kMax, cw.count, tw.count)
    var k = maxK
    while k > 0 {
      if Array(cw.suffix(k)).map({ $0.lowercased() })
        == Array(tw.prefix(k)).map({ $0.lowercased() })
      {
        break
      }
      k -= 1
    }
    let keptTail = Array(tw.dropFirst(k))
    return keptTail.isEmpty ? c : c + " " + keptTail.joined(separator: " ")
  }

  static func appendText(_ base: String, _ fragment: String) -> String {
    let f = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !f.isEmpty else { return base }
    let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
    return b.isEmpty ? f : b + " " + f
  }

  static func joinedText(_ results: [TranscriptionResult]) -> String {
    results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func wordEndTimes(_ results: [TranscriptionResult]) -> [Float]? {
    var ends: [Float] = []
    for r in results {
      for seg in r.segments {
        guard let words = seg.words else { continue }
        for w in words { ends.append(w.end) }
      }
    }
    return ends.isEmpty ? nil : ends
  }

  static func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return (sumSquares / Float(samples.count)).squareRoot()
  }

  /// Length (in samples) up to the last VOICED point — trailing low-energy audio
  /// (breath, room-tone, the silence that makes Whisper blurt "thank you") is
  /// trimmed. The threshold is RELATIVE to the clip's own peak speech level
  /// (`relFloor` × envelope peak), not a fixed absolute floor, so genuine breath
  /// below speech level is cut even though it is well above digital silence — the
  /// old absolute 0.001 floor only cut pure silence, which is why S2 never
  /// differed from the padded incumbent. A small absolute floor keeps it from
  /// trimming into legitimately quiet speech on a near-silent clip.
  static func trailingVoicedLength(
    _ samples: [Float], window: Int = 320, relFloor: Float = 0.15
  ) -> Int {
    guard !samples.isEmpty else { return 0 }
    var peak: Float = 0
    var i = 0
    while i < samples.count {
      peak = max(peak, rms(Array(samples[i..<min(samples.count, i + window)])))
      i += window
    }
    let thr = max(Float(0.004), relFloor * peak)
    var end = samples.count
    while end > 0 {
      let lo = max(0, end - window)
      if rms(Array(samples[lo..<end])) >= thr { break }
      end = lo
    }
    return end
  }
}
