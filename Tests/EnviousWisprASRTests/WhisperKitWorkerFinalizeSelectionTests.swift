import EnviousWisprCore
import Foundation
import Testing
@preconcurrency import WhisperKit

@testable import EnviousWisprASR

/// #1275 item B: the 30s-boundary candidate-selection fix. A recording that
/// crosses the boundary between the worker's last short-mode decode and
/// finalize must use the worker's `lastFullResult`, not discard it because
/// `accumulatedText` (the long-mode accumulation) is empty.
@Suite("WhisperKitIncrementalWorker.selectCandidateText")
struct SelectCandidateTextTests {

  @Test("short-mode: always returns lastFullResult regardless of accumulatedText")
  func test_shortMode_returnsLastFullResult() {
    let result = WhisperKitIncrementalWorker.selectCandidateText(
      isLong: false, accumulatedText: "", lastFullResult: "hello world")
    #expect(result == "hello world")
  }

  @Test("long-mode: non-empty accumulatedText wins (existing long-path behavior preserved)")
  func test_longMode_nonEmptyAccumulated_wins() {
    let result = WhisperKitIncrementalWorker.selectCandidateText(
      isLong: true, accumulatedText: "clipped accumulation", lastFullResult: "stale full result")
    #expect(result == "clipped accumulation")
  }

  @Test(
    "long-mode boundary case (#1275 B fix): empty accumulatedText falls back to lastFullResult instead of discarding"
  )
  func test_longMode_emptyAccumulated_fallsBackToLastFullResult() {
    let result = WhisperKitIncrementalWorker.selectCandidateText(
      isLong: true, accumulatedText: "", lastFullResult: "seven short-mode decodes worth of text")
    #expect(result == "seven short-mode decodes worth of text")
  }

  @Test("long-mode boundary case: whitespace-only accumulatedText also falls back")
  func test_longMode_whitespaceOnlyAccumulated_fallsBackToLastFullResult() {
    let result = WhisperKitIncrementalWorker.selectCandidateText(
      isLong: true, accumulatedText: "   \n  ", lastFullResult: "the real text")
    #expect(result == "the real text")
  }

  @Test("long-mode: both empty returns nil (preserves no_worker fallback)")
  func test_longMode_bothEmpty_returnsNil() {
    let result = WhisperKitIncrementalWorker.selectCandidateText(
      isLong: true, accumulatedText: "", lastFullResult: nil)
    #expect(result == nil)
  }

  @Test("short-mode: nil lastFullResult returns nil (preserves no_worker fallback)")
  func test_shortMode_nilLastFullResult_returnsNil() {
    let result = WhisperKitIncrementalWorker.selectCandidateText(
      isLong: false, accumulatedText: "irrelevant in short mode", lastFullResult: nil)
    #expect(result == nil)
  }
}

/// Scripted fake decoder — returns each entry in order, one per `transcribe`
/// call, so a test can assert exactly what the worker's run loop and tail
/// decode saw.
private actor FakeWhisperKitTranscribing: WhisperKitTranscribing {
  private var scriptedResults: [[TranscriptionResult]]
  private(set) var callCount = 0

  init(scriptedResults: [[TranscriptionResult]]) {
    self.scriptedResults = scriptedResults
  }

  func transcribe(audioArray: [Float], decodeOptions: DecodingOptions?) async throws
    -> [TranscriptionResult]
  {
    let index = callCount
    callCount += 1
    guard index < scriptedResults.count else { return [] }
    return scriptedResults[index]
  }
}

private func makeResult(text: String) -> TranscriptionResult {
  TranscriptionResult(text: text, segments: [], language: "en", timings: TranscriptionTimings())
}

/// Worker-level finalize characterization via a real (fast-cadence) run loop
/// + scripted fake decoder — proves the fix end-to-end, not just the pure
/// selection function, for the exact boundary session shape from the
/// founder's 2026-07-02 log: several short-mode cadence decodes, then a final
/// sample count that crosses the 480,000-sample (30s) threshold.
@Suite("WhisperKitIncrementalWorker.finalize boundary characterization")
struct WorkerFinalizeBoundaryTests {

  private static let longRecordingThreshold = 16_000 * 30  // 480,000 samples

  @Test(
    "boundary session: short-mode decodes then final count crosses 480,000 uses worker text (not no_worker) (#1275 B)"
  )
  func test_boundarySession_usesWorkerText() async throws {
    let shortModeSampleCount = 400_000  // under threshold — short mode
    let fake = FakeWhisperKitTranscribing(scriptedResults: [
      [makeResult(text: "why are you wearing")],
      [makeResult(text: "why are you wearing lingerie outside")],
    ])
    let worker = WhisperKitIncrementalWorker(
      whisperKit: fake, decodingOptions: DecodingOptions(), cadence: .milliseconds(20))

    let samples = [Float](repeating: 0, count: shortModeSampleCount)
    await worker.start(audioSamplesProvider: { (samples: samples, count: samples.count) })
    try await Task.sleep(for: .milliseconds(150))  // let >=2 short-mode decodes fire

    // finalSamples crosses the 30s boundary; the tail beyond shortModeSampleCount
    // is silence (all zeros), so the RMS gate skips the tail decode — this
    // isolates the assertion to candidate selection, not the tail path.
    let finalSamples = [Float](repeating: 0, count: Self.longRecordingThreshold + 20_000)
    let result = await worker.finalize(finalSamples: finalSamples, speechSegments: [])

    #expect(result.decodeCount > 0)
    #expect(result.strategy != "no_worker")
    #expect(result.accepted == true)
    #expect(result.text != nil)
  }

  @Test("off-by-one: final count exactly at threshold (480,000) stays short-mode")
  func test_finalCount_exactlyAtThreshold_staysShortMode() async throws {
    let fake = FakeWhisperKitTranscribing(scriptedResults: [
      [makeResult(text: "short mode decode")]
    ])
    let worker = WhisperKitIncrementalWorker(
      whisperKit: fake, decodingOptions: DecodingOptions(), cadence: .milliseconds(20))

    let samples = [Float](repeating: 0, count: 300_000)
    await worker.start(audioSamplesProvider: { (samples: samples, count: samples.count) })
    try await Task.sleep(for: .milliseconds(60))

    // isLong = count > threshold (strict), so exactly the threshold is short-mode.
    let finalSamples = [Float](repeating: 0, count: Self.longRecordingThreshold)
    let result = await worker.finalize(finalSamples: finalSamples, speechSegments: [])

    #expect(result.mode.hasPrefix("full"))  // short-mode base, not "clipped"
  }

  @Test("off-by-one: final count one sample past threshold (480,001) is long-mode")
  func test_finalCount_onePastThreshold_isLongMode() async throws {
    let fake = FakeWhisperKitTranscribing(scriptedResults: [
      [makeResult(text: "short mode decode")]
    ])
    let worker = WhisperKitIncrementalWorker(
      whisperKit: fake, decodingOptions: DecodingOptions(), cadence: .milliseconds(20))

    let samples = [Float](repeating: 0, count: 300_000)
    await worker.start(audioSamplesProvider: { (samples: samples, count: samples.count) })
    try await Task.sleep(for: .milliseconds(60))

    let finalSamples = [Float](repeating: 0, count: Self.longRecordingThreshold + 1)
    let result = await worker.finalize(finalSamples: finalSamples, speechSegments: [])

    #expect(result.mode.hasPrefix("clipped"))  // long-mode base
    // #1275 B fix: even though long-mode, the empty accumulatedText (worker
    // never took the isLongRecording branch) must fall back to the worker's
    // short-mode text, not discard it as no_worker.
    #expect(result.strategy != "no_worker")
  }

  @Test("stale worker with large uncovered tail (real speech) routes through tail decode")
  func test_staleWorker_largeUncoveredTail_routesThroughTailDecode() async throws {
    let shortModeSampleCount = 100_000
    let fake = FakeWhisperKitTranscribing(scriptedResults: [
      [makeResult(text: "the beginning of the sentence")],
      [makeResult(text: "the rest of the sentence")],  // tail decode result
    ])
    // Adversarial-review finding (#1275): the original 20ms cadence / 30ms
    // sleep gave only ~1.5x margin (10ms) for the first decode to land
    // before cancel() — a real CI-flakiness risk under scheduler contention,
    // since typical OS scheduler jitter is a roughly fixed few-ms magnitude
    // rather than a percentage of the interval. The sleep must land strictly
    // between one cadence tick (≥1 decode fires) and two (the fake's second
    // scripted entry, meant for the LATER tail-decode call, is never
    // consumed by a second cadence decode) — 40ms cadence / 60ms sleep keeps
    // the same 50% margin ratio but doubles the absolute buffer on each side
    // (20ms vs 10ms), meaningfully more robust to scheduler jitter.
    let worker = WhisperKitIncrementalWorker(
      whisperKit: fake, decodingOptions: DecodingOptions(), cadence: .milliseconds(40))

    let samples = [Float](repeating: 0, count: shortModeSampleCount)
    await worker.start(audioSamplesProvider: { (samples: samples, count: samples.count) })
    try await Task.sleep(for: .milliseconds(60))
    await worker.cancel()  // stop after exactly one short-mode decode

    // Large uncovered tail with actual signal (not silence) so the RMS gate
    // triggers the tail decode.
    var finalSamples = [Float](repeating: 0, count: shortModeSampleCount)
    finalSamples.append(contentsOf: (0..<200_000).map { Float(sin(Double($0) * 0.1)) * 0.5 })
    let result = await worker.finalize(finalSamples: finalSamples, speechSegments: [])

    #expect(result.strategy == "worker+tail")
    #expect(result.text?.contains("the rest of the sentence") == true)
  }
}

/// #1275 item D: the worker/tail seam-overlap trim. Reproduced 2026-07-02 via
/// controlled TTS (`why are you wearing lingerie outside?` / tail starting
/// `gerie outside?`) and via the founder's own log capture.
@Suite("WhisperKitIncrementalWorker.joinWithOverlapTrim")
struct JoinWithOverlapTrimTests {

  @Test("exact overlap: tail repeats the candidate's full tail phrase")
  func test_exactOverlap() {
    let result = WhisperKitIncrementalWorker.joinWithOverlapTrim(
      "the meeting starts at nine", "at nine we should be ready")
    #expect(result == "the meeting starts at nine we should be ready")
  }

  @Test("partial-token overlap: tail starts mid-word, matching source case (#1275 founder repro)")
  func test_partialTokenOverlap() {
    let result = WhisperKitIncrementalWorker.joinWithOverlapTrim(
      "why are you wearing lingerie outside?", "gerie outside? She's like, doing dishes.")
    #expect(result == "why are you wearing lingerie outside? She's like, doing dishes.")
  }

  @Test("partial-token overlap is case-insensitive")
  func test_partialTokenOverlap_caseInsensitive() {
    let result = WhisperKitIncrementalWorker.joinWithOverlapTrim(
      "why are you wearing LINGERIE outside?", "gerie Outside? She's like, doing dishes.")
    #expect(result == "why are you wearing LINGERIE outside? She's like, doing dishes.")
  }

  @Test("no overlap: naive join preserved")
  func test_noOverlap_naiveJoin() {
    let result = WhisperKitIncrementalWorker.joinWithOverlapTrim(
      "hello there, how are you", "completely unrelated continuation text")
    #expect(result == "hello there, how are you completely unrelated continuation text")
  }

  @Test(
    "short coincidental match below minOverlap does not trim (Codex r1 P2 repro: 'I am' / 'amazing today')"
  )
  func test_shortCoincidentalMatch_belowMinOverlap_noTrim() {
    let result = WhisperKitIncrementalWorker.joinWithOverlapTrim("I am", "amazing today")
    #expect(result == "I am amazing today")
  }

  @Test("empty tail returns candidate unchanged")
  func test_emptyTail_returnsCandidate() {
    let result = WhisperKitIncrementalWorker.joinWithOverlapTrim("candidate text", "")
    #expect(result == "candidate text")
  }

  @Test("empty candidate returns tail unchanged")
  func test_emptyCandidate_returnsTail() {
    let result = WhisperKitIncrementalWorker.joinWithOverlapTrim("", "tail text")
    #expect(result == "tail text")
  }

  @Test("diverging trailing punctuation prevents a match (no wrong trim)")
  func test_divergingPunctuation_noMatch() {
    // Candidate ends "No." (period); tail starts "No," (comma) — literal
    // mismatch at the boundary, so the trimmer must not guess a match.
    let result = WhisperKitIncrementalWorker.joinWithOverlapTrim(
      "I said no.", "No, I really mean it.")
    #expect(result == "I said no. No, I really mean it.")
  }

  @Test(
    "legitimate repeated word at the seam is trimmed (accepted residual risk, #1275 §7 — documents current behavior, not a target to preserve)"
  )
  func test_legitimateRepetitionAtSeam_isTrimmed() {
    // The speaker genuinely said "outside outside" — text alone cannot
    // distinguish this from acoustic-overlap duplication, so one copy is
    // lost. This is the accepted trade-off documented in the plan's §7
    // failure-mode table; the test exists so a future change to this
    // behavior is a deliberate decision, not a silent regression.
    let result = WhisperKitIncrementalWorker.joinWithOverlapTrim(
      "he was standing outside", "outside in the pouring rain")
    #expect(result == "he was standing outside in the pouring rain")
  }

  @Test("bounded window: overlap beyond ~80 characters is not matched")
  func test_overlapBeyondWindow_notMatched() {
    let longRepeatedSuffix = String(repeating: "word ", count: 30)  // 150 chars
    let candidate = "prefix text " + longRepeatedSuffix
    let tail = longRepeatedSuffix + "continuation"
    let result = WhisperKitIncrementalWorker.joinWithOverlapTrim(candidate, tail)
    // The true overlap (150 chars) exceeds the 80-char window, so only a
    // partial match within the window is found (or none) — assert the
    // function terminates and never drops the tail's continuation.
    #expect(result.contains("continuation"))
  }

  @Test(
    "no-op sweep over unrelated sentence pairs: no unwanted trims across a small representative corpus"
  )
  func test_noOpSweep_unrelatedPairs() {
    // Lighter-weight stand-in for "run over a large fixed text corpus" —
    // representative sentence-boundary pairs with no genuine audio-overlap
    // duplication. None should trim any text from the tail.
    let pairs: [(String, String)] = [
      ("The quarterly report needs two more charts.", "It should be ready by Friday."),
      ("She picked up the phone and said hello.", "Then she waited for a response."),
      ("The weather today is sunny and warm.", "Tomorrow looks like rain."),
      ("He finished the presentation early.", "The client seemed impressed."),
      ("We should schedule a follow-up meeting.", "Next Tuesday works for everyone."),
    ]
    for (candidate, tail) in pairs {
      let result = WhisperKitIncrementalWorker.joinWithOverlapTrim(candidate, tail)
      #expect(result == candidate + " " + tail)
    }
  }
}
