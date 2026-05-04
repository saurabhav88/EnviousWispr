@preconcurrency import FluidAudio
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
}
