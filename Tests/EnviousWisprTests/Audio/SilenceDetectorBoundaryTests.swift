@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

@Suite("SilenceDetector boundary events")
struct SilenceDetectorBoundaryTests {
  @Test("FluidAudio speech events define segment boundaries")
  func streamEventsDefineSegmentBoundaries() async {
    let detector = SilenceDetector()

    await detector.applyStreamBoundary(
      VadStreamEvent(kind: .speechStart, sampleIndex: 4_096)
    )
    await detector.applyStreamBoundary(
      VadStreamEvent(kind: .speechEnd, sampleIndex: 20_480)
    )

    let segments = await detector.speechSegments
    #expect(segments.count == 1)
    #expect(segments.first?.startSample == 4_096)
    #expect(segments.first?.endSample == 20_480)
  }

  @Test("manual stop finalizes an open stream-event segment")
  func finalizeSegmentsClosesOpenBoundary() async {
    let detector = SilenceDetector()

    await detector.applyStreamBoundary(
      VadStreamEvent(kind: .speechStart, sampleIndex: 8_192)
    )
    await detector.finalizeSegments(totalSampleCount: 24_000)

    let segments = await detector.speechSegments
    #expect(segments.count == 1)
    #expect(segments.first?.startSample == 8_192)
    #expect(segments.first?.endSample == 24_000)
  }

  @Test("invalid speech end does not emit a malformed segment")
  func invalidSpeechEndDoesNotEmitSegment() async {
    let detector = SilenceDetector()

    await detector.applyStreamBoundary(
      VadStreamEvent(kind: .speechStart, sampleIndex: 12_288)
    )
    await detector.applyStreamBoundary(
      VadStreamEvent(kind: .speechEnd, sampleIndex: 12_288)
    )

    let segments = await detector.speechSegments
    #expect(segments.isEmpty)
  }

  // MARK: - Two-signal separation (issue #604 contract)
  //
  // These tests lock the contract that segment boundaries come from FluidAudio
  // events while auto-stop comes from the smoothed-EMA + hangover state machine,
  // and that the two signals do not cross. If a future refactor migrates either
  // signal onto the other path, these tests must be updated deliberately.

  /// Deterministic config for state-machine tests: emaAlpha=1.0 means the
  /// smoothed probability equals the raw input, so a single high-probability
  /// chunk transitions idle → speech and a single zero-probability chunk
  /// transitions speech → hangover.
  private static let lockingTestConfig = SmoothedVADConfig(
    emaAlpha: 1.0,
    onsetThreshold: 0.5,
    offsetThreshold: 0.4,
    onsetConfirmationChunks: 1,
    hangoverChunks: 3,
    prebufferChunks: 0,
    energyGateThreshold: 0.0
  )

  @Test("auto-stop fires from the smoothed-EMA path with no stream events")
  func autoStopFiresFromSmoothedEMAPath() async {
    let detector = SilenceDetector(
      silenceTimeout: 0.5, vadConfig: Self.lockingTestConfig)

    let enteredSpeech = await detector.advanceStateMachine(
      rawProbability: 1.0, samplesInChunk: SilenceDetector.chunkSize)
    #expect(enteredSpeech == false)
    let speechDetected = await detector.speechDetected
    #expect(speechDetected == true)

    var sawAutoStop = false
    for _ in 0..<32 {
      let stop = await detector.advanceStateMachine(
        rawProbability: 0.0, samplesInChunk: SilenceDetector.chunkSize)
      if stop {
        sawAutoStop = true
        break
      }
    }
    #expect(sawAutoStop == true, "smoothed-EMA hangover must drive auto-stop")
  }

  @Test("smoothed-EMA hangover does NOT append to speechSegments")
  func autoStopDoesNotProduceSegments() async {
    let detector = SilenceDetector(
      silenceTimeout: 0.5, vadConfig: Self.lockingTestConfig)

    _ = await detector.advanceStateMachine(
      rawProbability: 1.0, samplesInChunk: SilenceDetector.chunkSize)

    var sawAutoStop = false
    for _ in 0..<32 {
      let stop = await detector.advanceStateMachine(
        rawProbability: 0.0, samplesInChunk: SilenceDetector.chunkSize)
      if stop {
        sawAutoStop = true
        break
      }
    }
    #expect(sawAutoStop == true, "precondition: auto-stop must have fired")

    let segments = await detector.speechSegments
    #expect(
      segments.isEmpty,
      "smoothed-EMA hangover must NOT close segments — that's the event path's job")
  }

  @Test("event-opened segment survives auto-stop; finalize closes it")
  func eventStartSurvivesAutoStopAndFinalizeCloses() async {
    let detector = SilenceDetector(
      silenceTimeout: 0.5, vadConfig: Self.lockingTestConfig)

    await detector.applyStreamBoundary(
      VadStreamEvent(kind: .speechStart, sampleIndex: 1_024)
    )

    _ = await detector.advanceStateMachine(
      rawProbability: 1.0, samplesInChunk: SilenceDetector.chunkSize)

    for _ in 0..<32 {
      let stop = await detector.advanceStateMachine(
        rawProbability: 0.0, samplesInChunk: SilenceDetector.chunkSize)
      if stop { break }
    }

    let preFinalize = await detector.speechSegments
    #expect(
      preFinalize.isEmpty,
      "auto-stop must leave the open segment untouched; only events or finalize close")

    await detector.finalizeSegments(totalSampleCount: 32_000)
    let postFinalize = await detector.speechSegments
    #expect(postFinalize.count == 1)
    #expect(postFinalize.first?.startSample == 1_024)
    #expect(postFinalize.first?.endSample == 32_000)
  }

  // MARK: - Energy-gate clock-alignment guard (issue #604 followup)
  //
  // FluidAudio's VadStreamEvent.sampleIndex is computed in VadStreamState's
  // internal sample clock, which only advances inside processStreamingChunk.
  // Skipping that call on energy-gated chunks would drift the FluidAudio clock
  // away from our buffer index, producing wrong SpeechSegment boundaries
  // (Codex flagged this on 2026-05-04). The contract: processStreamingChunk runs
  // on EVERY chunk, before the energy gate can zero the smoothed-EMA input.
  //
  // #905 replaced an earlier text-grep test (which read SilenceDetector.swift as
  // a String and asserted the call literal appeared before the gate literal —
  // blind to wrong arguments, drifted indices, or a runtime branch hiding the
  // skip) with these behavioral tests: a fake `StreamingVad` records each call
  // and the `processedSamples` clock it was handed, so a gated chunk that skips
  // the call (the pre-#604 regression) or a dropped `streamState = result.state`
  // is caught by running the real `processChunk`, not by grepping source.

  @Test(
    "energy-gated quiet chunks still advance the FluidAudio streaming clock",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/905",
      "energy gate must not skip the per-chunk VAD streaming call"
    )
  )
  func gatedChunksStillAdvanceStreamingClock() async throws {
    let fake = FakeStreamingVad()
    // energyGateThreshold > 0 so a silent chunk (RMS 0) is energy-gated — the
    // exact case the pre-#604 bug skipped the streaming call on.
    let detector = SilenceDetector(
      vadConfig: SmoothedVADConfig(energyGateThreshold: 0.5),
      makeStreamingVad: { fake }
    )
    try await detector.prepare()

    let quiet = [Float](repeating: 0.0, count: SilenceDetector.chunkSize)
    _ = await detector.processChunk(quiet)
    _ = await detector.processChunk(quiet)

    let seen = await fake.seenProcessedSamples
    #expect(seen.count == 2)  // the streaming call fired on BOTH gated chunks
    #expect(seen[1] > seen[0])  // state propagated — the clock advanced across chunks
  }

  @Test("a non-gated (loud) chunk also advances the streaming clock")
  func loudChunkAlsoAdvancesStreamingClock() async throws {
    let fake = FakeStreamingVad()
    let detector = SilenceDetector(
      vadConfig: SmoothedVADConfig(energyGateThreshold: 0.5),
      makeStreamingVad: { fake }
    )
    try await detector.prepare()

    // RMS 0.8 ≥ threshold 0.5 → NOT energy-gated (the adversarial other side).
    let loud = [Float](repeating: 0.8, count: SilenceDetector.chunkSize)
    _ = await detector.processChunk(loud)
    _ = await detector.processChunk(loud)

    let seen = await fake.seenProcessedSamples
    #expect(seen.count == 2)
    #expect(seen[1] > seen[0])
  }
}

/// Records each `processStreamingChunk` call and the `processedSamples` clock it
/// was handed, then returns a result that advances that clock by the chunk size
/// (mirroring FluidAudio's `VadManager+Streaming`). An `actor` so it satisfies
/// the `Sendable` `StreamingVad` seam under Swift 6.
actor FakeStreamingVad: StreamingVad {
  private(set) var seenProcessedSamples: [Int] = []

  func processStreamingChunk(
    _ audioChunk: [Float],
    state: VadStreamState,
    config: VadSegmentationConfig,
    returnSeconds: Bool,
    timeResolution: Int
  ) async throws -> VadStreamResult {
    seenProcessedSamples.append(state.processedSamples)
    var next = state
    next.processedSamples += audioChunk.count
    return VadStreamResult(state: next, event: nil, probability: 0.0)
  }
}
