import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

/// #2184 — the conditioning transform itself, and the two wiring facts that
/// decide whether it helps or harms.
///
/// **What the user sees when these fail:** either the opening words of a
/// dictation recorded in a noisy room are still lost (the filter is not reaching
/// the VAD, or its state is wrong at session start), or soft and whispered
/// speech starts being dropped in a quiet room (the filter has leaked into the
/// energy gate, which then reads audio it has just removed the energy from).
@Suite("VAD input high-pass", .tags(.productOutcome))
struct VADInputHighPassTests {

  // MARK: - The transform

  @Test("a session never inherits the previous session's filter state")
  func resetRestoresTheFirstChunkExactly() {
    var filter = VADInputHighPass()
    let first = Self.tone(hz: 60, samples: 4_096, amplitude: 0.3)
    let second = Self.tone(hz: 900, samples: 4_096, amplitude: 0.3)

    let sessionOneChunkOne = filter.process(first)
    _ = filter.process(second)  // leave the sections carrying state
    filter.reset()
    let sessionTwoChunkOne = filter.process(first)

    #expect(
      sessionTwoChunkOne == sessionOneChunkOne,
      "the first chunk after a reset differs from the first chunk of a fresh session, so a recording is being conditioned on the previous recording's tail"
    )
  }

  /// The reason `reset()` has to exist at all: without it, the state left behind
  /// by the previous session changes this one's opening samples. If this ever
  /// passes, the test above has stopped being able to fail.
  @Test("carried-over state genuinely changes the opening samples")
  func statePersistenceIsObservable() {
    var filter = VADInputHighPass()
    let first = Self.tone(hz: 60, samples: 4_096, amplitude: 0.3)
    let fresh = filter.process(first)

    var carried = VADInputHighPass()
    _ = carried.process(Self.tone(hz: 60, samples: 4_096, amplitude: 0.9))
    let afterCarry = carried.process(first)

    #expect(afterCarry != fresh)
  }

  /// The filter is IIR and the detector feeds it 4096 samples at a time, so
  /// per-chunk output must equal whole-buffer output. If it does not, every
  /// chunk boundary is a discontinuity the VAD can see — which is the class of
  /// artefact this change exists to remove, not add.
  @Test("chunked filtering equals filtering the whole buffer at once")
  func chunkedMatchesWholeBuffer() {
    let buffer = Self.tone(hz: 120, samples: 4_096 * 3, amplitude: 0.4)

    var whole = VADInputHighPass()
    let wholeOutput = whole.process(buffer)

    var chunked = VADInputHighPass()
    var chunkedOutput: [Float] = []
    for start in stride(from: 0, to: buffer.count, by: 4_096) {
      chunkedOutput += chunked.process(Array(buffer[start..<(start + 4_096)]))
    }

    #expect(chunkedOutput == wholeOutput)
  }

  @Test("low frequencies are removed and speech frequencies are kept")
  func attenuatesBelowTheParameterAndPassesAbove() {
    // Measured through the transform rather than asserted from theory: the
    // claim under test is the one the VAD depends on, which is that cabin
    // rumble is removed while the band a voice lives in survives.
    //
    // The 900 Hz number is also the cheapest available demonstration that **250
    // is the per-section parameter, not the cascade's −3 dB point**: a filter
    // whose corner really sat at 250 Hz would pass 900 Hz essentially intact,
    // and this one takes about 15% off it. Measured 0.055 and 0.850; the bounds
    // below are loose around those.
    let lowIn = Self.tone(hz: 60, samples: 16_384, amplitude: 0.5)
    let highIn = Self.tone(hz: 900, samples: 16_384, amplitude: 0.5)
    var lowFilter = VADInputHighPass()
    var highFilter = VADInputHighPass()

    let lowRatio = Self.rms(lowFilter.process(lowIn)) / Self.rms(lowIn)
    let highRatio = Self.rms(highFilter.process(highIn)) / Self.rms(highIn)

    #expect(lowRatio < 0.10, "60 Hz survived at \(lowRatio) of its input energy")
    #expect(highRatio > 0.80, "900 Hz was cut to \(highRatio) of its input energy")
  }

  @Test("output length always equals input length")
  func lengthIsPreserved() {
    var filter = VADInputHighPass()
    for count in [0, 1, 4_095, 4_096] {
      #expect(filter.process([Float](repeating: 0.1, count: count)).count == count)
    }
  }

  // MARK: - The wiring

  /// The VAD must receive the conditioned copy. Fed a pure 60 Hz tone — all of
  /// it below the parameter — the array the model sees is nearly empty while the
  /// array the detector was handed is not.
  @Test("the VAD model receives the conditioned chunk")
  func vadReceivesConditionedSamples() async throws {
    let probe = ProbeStreamingVad(probability: 0.0)
    let detector = SilenceDetector(
      silenceTimeout: 1.5,
      vadConfig: SmoothedVADConfig(),
      makeStreamingVad: { probe }
    )
    try await detector.prepare()

    let rumble = Self.tone(hz: 60, samples: 4_096, amplitude: 0.3)
    _ = await detector.processChunk(rumble)

    let seen = try #require(await probe.lastChunk)
    #expect(seen.count == rumble.count)
    #expect(
      Self.rms(seen) < Self.rms(rumble) * 0.25,
      "the VAD saw RMS \(Self.rms(seen)) against a raw \(Self.rms(rumble)) — the conditioning is not reaching the model"
    )
  }

  /// The energy gate must keep reading RAW samples. The filter *removes* energy,
  /// so a gate reading filtered audio silently becomes a stricter soft-speech
  /// threshold — it would zero more chunks, which is the opposite of this
  /// change's intent and would cost exactly the whispered speech we are trying
  /// to protect.
  ///
  /// Asserted as an outcome, not as a code shape. The chunk below has a raw RMS
  /// above the gate threshold and a conditioned RMS well below it, so the two
  /// wirings disagree about whether the model's probability survives, and the
  /// detector either enters its speech phase or does not.
  @Test("the energy gate reads the unfiltered chunk")
  func energyGateReadsRawSamples() async throws {
    let rumble = Self.tone(hz: 60, samples: 4_096, amplitude: 0.3)
    var reference = VADInputHighPass()
    let conditionedRMS = Self.rms(reference.process(rumble))
    let rawRMS = Self.rms(rumble)

    // Prove the input actually straddles the threshold before relying on it. A
    // chunk that sits on one side of the gate for both wirings would make this
    // test pass whatever the detector does.
    let gate: Float = 0.05
    try #require(rawRMS > gate, "raw RMS \(rawRMS) does not clear the gate")
    try #require(conditionedRMS < gate, "conditioned RMS \(conditionedRMS) also clears the gate")

    let probe = ProbeStreamingVad(probability: 0.9)
    let detector = SilenceDetector(
      silenceTimeout: 1.5,
      vadConfig: SmoothedVADConfig(
        emaAlpha: 1.0,
        onsetThreshold: 0.5,
        offsetThreshold: 0.4,
        onsetConfirmationChunks: 1,
        hangoverChunks: 3,
        prebufferChunks: 0,
        energyGateThreshold: gate
      ),
      makeStreamingVad: { probe }
    )
    try await detector.prepare()

    _ = await detector.processChunk(rumble)

    #expect(
      await detector.speechDetected,
      "the detector stayed idle on a chunk whose RAW energy clears the gate — the gate is reading the conditioned array, which makes it a stricter soft-speech threshold"
    )
  }

  // MARK: - Helpers

  private static func tone(hz: Double, samples: Int, amplitude: Double) -> [Float] {
    (0..<samples).map { index in
      Float(amplitude * sin(2.0 * Double.pi * hz * Double(index) / AudioConstants.sampleRate))
    }
  }

  private static func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let total = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    return Float((total / Double(samples.count)).squareRoot())
  }
}

/// Records the array handed to the model and returns a fixed probability, so a
/// test can separate "what the VAD saw" from "what the detector was given".
private actor ProbeStreamingVad: StreamingVad {
  private let probability: Float
  private(set) var lastChunk: [Float]?

  init(probability: Float) {
    self.probability = probability
  }

  func processStreamingChunk(
    _ audioChunk: [Float],
    state: VadStreamState,
    config: VadSegmentationConfig,
    returnSeconds: Bool,
    timeResolution: Int
  ) async throws -> VadStreamResult {
    lastChunk = audioChunk
    var next = state
    next.processedSamples += audioChunk.count
    return VadStreamResult(state: next, event: nil, probability: probability)
  }
}
