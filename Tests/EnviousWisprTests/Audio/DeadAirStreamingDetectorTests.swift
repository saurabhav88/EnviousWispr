import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// #1317 §3.1 — the app-side mid-recording all-zero harness-glitch detector.
// Streaming, buffer-by-buffer, so these boundary cases matter twice: once for
// the classification rules themselves, and once for the EQUIVALENCE claim
// that a streaming classification agrees with a one-shot classification made
// after the fact over the same concatenated samples — the plan's split-buffer
// tile test (a 640-sample tile straddling two proxy callbacks must not
// classify differently than the same audio delivered in one buffer).
@Suite("Dead-air streaming detector (#1317)")
struct DeadAirStreamingDetectorTests {

  private let threshold = AudioConstants.minimumTranscriptionSamples  // 16_000

  private func ingestWhole(_ samples: [Float]) -> DeadAirStreamingDetector {
    var detector = DeadAirStreamingDetector()
    samples.withUnsafeBufferPointer { detector.ingest($0) }
    return detector
  }

  /// Ingests `samples` split into `chunkSize`-sized buffers (the last chunk
  /// may be shorter), simulating real proxy delivery where buffer boundaries
  /// do not align to the 640-sample tile grid.
  private func ingestChunked(_ samples: [Float], chunkSize: Int) -> DeadAirStreamingDetector {
    var detector = DeadAirStreamingDetector()
    var i = 0
    while i < samples.count {
      let end = min(i + chunkSize, samples.count)
      let slice = Array(samples[i..<end])
      slice.withUnsafeBufferPointer { detector.ingest($0) }
      i = end
    }
    return detector
  }

  // MARK: - allZeroFromStart

  @Test("every sample exactly zero, at threshold → allZeroFromStart")
  func allZeroFromStartAtThreshold() {
    let detector = ingestWhole([Float](repeating: 0, count: threshold))
    #expect(detector.isAllZeroFromStart(ceilingSamples: threshold))
    #expect(!detector.isBecameZeroMidCapture)
  }

  @Test("every sample exactly zero, BELOW threshold → not yet confident")
  func allZeroBelowThresholdNotYetConfident() {
    let detector = ingestWhole([Float](repeating: 0, count: threshold - 1))
    #expect(!detector.isAllZeroFromStart(ceilingSamples: threshold))
  }

  // MARK: - No false alarm on genuine quiet-room noise

  /// The discriminator is exact-zero, not amplitude — ANY non-zero noise,
  /// however tiny, must never read as the harness glitch. Uses the same
  /// uniform-0.001 shape `RecordingSessionKernelDeadAirFloorTests` uses for
  /// "dead air but not silence" — below every `RawAudioDeadAirClassifier`
  /// floor, yet not literally zero.
  @Test("uniform tiny non-zero noise never triggers allZeroFromStart")
  func quietRoomNoiseNeverFalseAlarms() {
    let detector = ingestWhole([Float](repeating: 0.001, count: threshold * 2))
    #expect(!detector.isAllZeroFromStart(ceilingSamples: threshold))
    #expect(!detector.isBecameZeroMidCapture)
  }

  @Test("a single non-zero sample among zeros breaks allZeroFromStart")
  func oneNonZeroSampleBreaksAllZeroFromStart() {
    var samples = [Float](repeating: 0, count: threshold)
    samples[threshold / 2] = 0.01
    let detector = ingestWhole(samples)
    #expect(!detector.isAllZeroFromStart(ceilingSamples: threshold))
  }

  // MARK: - becameZeroMidCapture

  @Test("meaningful signal then a sustained zero suffix → becameZeroMidCapture")
  func meaningfulThenZeroBecomesMidCapture() {
    var samples = [Float](repeating: 0.1, count: 4_000)  // clearly above every floor
    samples.append(contentsOf: [Float](repeating: 0, count: threshold))
    let detector = ingestWhole(samples)
    #expect(detector.meaningfulSignalSeen)
    #expect(detector.isBecameZeroMidCapture)
    #expect(!detector.isAllZeroFromStart(ceilingSamples: threshold))
  }

  @Test("meaningful signal then a zero suffix BELOW threshold → not yet confident")
  func meaningfulThenShortZeroSuffixNotYetConfident() {
    var samples = [Float](repeating: 0.1, count: 4_000)
    samples.append(contentsOf: [Float](repeating: 0, count: threshold - 1))
    let detector = ingestWhole(samples)
    #expect(detector.meaningfulSignalSeen)
    #expect(!detector.isBecameZeroMidCapture)
  }

  @Test("dead-air-floor noise then zero — no meaningful signal, so no becameZeroMidCapture")
  func deadAirNoiseThenZeroIsNotBecameZeroMidCapture() {
    var samples = [Float](repeating: 0.001, count: 4_000)  // below every dead-air floor
    samples.append(contentsOf: [Float](repeating: 0, count: threshold))
    let detector = ingestWhole(samples)
    #expect(!detector.meaningfulSignalSeen)
    #expect(!detector.isBecameZeroMidCapture)
  }

  @Test(
    "zero suffix that never resumes non-zero, with no prior signal, stays allZeroFromStart-only")
  func zeroSuffixWithoutPriorSignalIsNotBecameZero() {
    let detector = ingestWhole([Float](repeating: 0, count: threshold))
    #expect(!detector.meaningfulSignalSeen)
    #expect(!detector.isBecameZeroMidCapture)
    #expect(detector.isAllZeroFromStart(ceilingSamples: threshold))
  }

  @Test("meaningful signal that never goes to zero triggers neither mode")
  func continuousSignalTriggersNeitherMode() {
    let detector = ingestWhole([Float](repeating: 0.1, count: threshold * 2))
    #expect(detector.meaningfulSignalSeen)
    #expect(!detector.isAllZeroFromStart(ceilingSamples: threshold))
    #expect(!detector.isBecameZeroMidCapture)
  }

  // MARK: - Split-buffer-boundary equivalence (the plan's mandatory test)

  /// A capture-start-aligned 640-sample tile split across two buffer
  /// callbacks must classify identically to the same audio delivered whole.
  /// The burst is NOT tile-aligned (starts at 3_700, not a multiple of 640)
  /// so the buffer split at `chunkSize: 500` guarantees at least one 640
  /// tile straddles two `ingest` calls.
  @Test("a tile split across two buffers agrees with one-shot classification")
  func splitBufferTileAgreesWithWholeArray() {
    var samples = [Float](repeating: 0, count: threshold)
    // A burst clearing every RawAudioDeadAirClassifier floor, straddling
    // multiple non-tile-aligned buffer boundaries when chunked at 500.
    for i in 3_700..<4_340 { samples[i] = 0.05 }
    samples.append(contentsOf: [Float](repeating: 0, count: threshold))

    let whole = ingestWhole(samples)
    let chunked = ingestChunked(samples, chunkSize: 500)

    #expect(whole.meaningfulSignalSeen == chunked.meaningfulSignalSeen)
    #expect(
      whole.isAllZeroFromStart(ceilingSamples: threshold)
        == chunked.isAllZeroFromStart(ceilingSamples: threshold))
    #expect(whole.isBecameZeroMidCapture == chunked.isBecameZeroMidCapture)
    #expect(whole.totalSampleCount == chunked.totalSampleCount)
    #expect(whole.consecutiveExactZeroSuffix == chunked.consecutiveExactZeroSuffix)

    // And both streaming results agree with a direct one-shot classification
    // of the meaningful prefix via the shared authority the plan requires
    // streaming stats to match (§3.1).
    let prefix = Array(samples[0..<4_340])
    let prefixPeak = prefix.reduce(Float(0)) { max($0, abs($1)) }
    let prefixIsDeadAir = RawAudioDeadAirClassifier.isDeadAir(prefix, peak: prefixPeak)
    #expect(whole.meaningfulSignalSeen == !prefixIsDeadAir)
  }

  /// Same equivalence claim, but for audio that never crosses the
  /// meaningful-signal floor at all — the all-dead-air whole capture must
  /// also agree at every chunk size.
  @Test("split-buffer equivalence holds for a whole all-zero capture too")
  func splitBufferAgreesForAllZeroCapture() {
    let samples = [Float](repeating: 0, count: threshold + 500)
    let whole = ingestWhole(samples)
    let chunked = ingestChunked(samples, chunkSize: 333)  // deliberately not a 640 divisor
    #expect(
      whole.isAllZeroFromStart(ceilingSamples: threshold)
        == chunked.isAllZeroFromStart(ceilingSamples: threshold))
    #expect(whole.isAllZeroFromStart(ceilingSamples: threshold))
  }

  // MARK: - RawAudioDeadAirClassifier.isDeadAir generic-slice equivalence

  /// #1317 (cloud review round 2, P2): `classifyZeroSignalAtStop` was
  /// changed to pass an `ArraySlice` prefix view instead of copying into a
  /// new `Array`, which required widening `isDeadAir` to a generic
  /// `RandomAccessCollection`. An `ArraySlice`'s indices are offset from
  /// the PARENT array's start, not zero-based — the windowed-RMS loop must
  /// use `startIndex`/`endIndex`, not raw `0..<count` arithmetic, or it
  /// reads the wrong elements (or traps) for any non-zero-offset slice.
  /// This proves array and a non-zero-offset slice of the SAME values agree.
  @Test("isDeadAir agrees for an Array and a non-zero-offset ArraySlice of the same values")
  func isDeadAirAgreesForArrayAndOffsetSlice() {
    var padded = [Float](repeating: 0.05, count: 1_000)  // clears every floor
    padded.append(contentsOf: [Float](repeating: 0, count: threshold))  // quiet prefix content
    let sliceStart = 1_000
    let slice = padded[sliceStart...]
    let array = Array(slice)
    #expect(slice.startIndex == sliceStart)  // sanity: genuinely non-zero-offset

    let arrayPeak = array.reduce(Float(0)) { max($0, abs($1)) }
    let slicePeak = slice.reduce(Float(0)) { max($0, abs($1)) }
    #expect(arrayPeak == slicePeak)

    let arrayResult = RawAudioDeadAirClassifier.isDeadAir(array, peak: arrayPeak)
    let sliceResult = RawAudioDeadAirClassifier.isDeadAir(slice, peak: slicePeak)
    #expect(arrayResult == sliceResult)
  }

  /// Same equivalence claim, but with a loud window positioned so an
  /// off-by-index-base bug would tile the WRONG 640-sample windows and
  /// silently produce a false `isDeadAir == true` (the danger case, since
  /// this feeds a fail-open decision) instead of just crashing.
  @Test("isDeadAir agrees for an Array and an ArraySlice with a loud embedded window")
  func isDeadAirAgreesForArrayAndOffsetSliceWithLoudWindow() {
    var padded = [Float](repeating: 0, count: 1_000)
    var body = [Float](repeating: 0, count: threshold)
    for i in 2_000..<2_640 { body[i] = 0.05 }  // one loud tile-aligned-in-body window
    padded.append(contentsOf: body)
    let slice = padded[1_000...]
    let array = Array(slice)
    #expect(slice.startIndex == 1_000)

    let peak: Float = 0.05
    let arrayResult = RawAudioDeadAirClassifier.isDeadAir(array, peak: peak)
    let sliceResult = RawAudioDeadAirClassifier.isDeadAir(slice, peak: peak)
    #expect(arrayResult == sliceResult)
    #expect(!arrayResult)  // the loud window must be found, not silently missed
  }

  // MARK: - Caller-supplied ceiling (#1788)
  //
  // The ceiling is a PARAMETER so the mid-take owner can raise it for a
  // transport that legitimately needs longer, without the detector knowing
  // anything about transports. These tests pin the boundary at an arbitrary
  // custom ceiling so they cannot silently pass just because it happens to
  // equal `minimumTranscriptionSamples`.

  @Test("custom ceiling: below it, all-zero is not yet confident")
  func customCeilingBelowIsNotConfident() {
    let ceiling = 48_000
    let detector = ingestWhole([Float](repeating: 0, count: ceiling - 1))
    #expect(!detector.isAllZeroFromStart(ceilingSamples: ceiling))
    // ...and the SAME samples DO trip the shipping 1.0s ceiling, proving the
    // parameter is what moved the verdict rather than the sample shape.
    #expect(detector.isAllZeroFromStart(ceilingSamples: threshold))
  }

  @Test("custom ceiling: exactly at it, all-zero fires")
  func customCeilingAtFires() {
    let ceiling = 48_000
    let detector = ingestWhole([Float](repeating: 0, count: ceiling))
    #expect(detector.isAllZeroFromStart(ceilingSamples: ceiling))
  }

  @Test("custom ceiling: one sample above it, all-zero fires")
  func customCeilingAboveFires() {
    let ceiling = 48_000
    let detector = ingestWhole([Float](repeating: 0, count: ceiling + 1))
    #expect(detector.isAllZeroFromStart(ceilingSamples: ceiling))
  }

  /// THE case the #1788 fix exists to protect: a link that wakes up late.
  /// Once any real sample arrives, all-zero-from-start must be false FOREVER
  /// for that generation, at every ceiling — otherwise a woken microphone
  /// could still be aborted later in the same take.
  @Test("a late wake makes all-zero-from-start permanently false at every ceiling")
  func lateWakeIsPermanentlyNotAllZero() {
    let ceiling = 48_000
    var samples = [Float](repeating: 0, count: ceiling - 1)
    samples.append(0.05)  // the link comes up
    samples.append(contentsOf: [Float](repeating: 0, count: ceiling * 2))  // then quiet again
    let detector = ingestWhole(samples)
    #expect(!detector.isAllZeroFromStart(ceilingSamples: threshold))
    #expect(!detector.isAllZeroFromStart(ceilingSamples: ceiling))
    #expect(!detector.isAllZeroFromStart(ceilingSamples: 1))
  }

  // MARK: - Zero-prefix diagnostic (#1788)

  @Test("zero prefix is nil while the capture is still entirely zeros")
  func zeroPrefixNilWhileAllZero() {
    let detector = ingestWhole([Float](repeating: 0, count: 5_000))
    #expect(detector.zeroPrefixSampleCount == nil)
  }

  @Test("zero prefix reports the leading zero count once real audio arrives")
  func zeroPrefixReportsLeadingZeroCount() {
    var samples = [Float](repeating: 0, count: 9_600)  // 600ms at 16kHz
    samples.append(0.02)
    let detector = ingestWhole(samples)
    #expect(detector.zeroPrefixSampleCount == 9_600)
  }

  @Test("zero prefix latches the FIRST wake, not a later one")
  func zeroPrefixLatchesFirstWake() {
    var samples = [Float](repeating: 0, count: 1_000)
    samples.append(0.02)
    samples.append(contentsOf: [Float](repeating: 0, count: 5_000))
    samples.append(0.03)
    let detector = ingestWhole(samples)
    #expect(detector.zeroPrefixSampleCount == 1_000)
  }

  @Test("zero prefix is 0 when audio flows from the very first sample")
  func zeroPrefixZeroWhenImmediatelyLive() {
    let detector = ingestWhole([Float](repeating: 0.02, count: 1_000))
    #expect(detector.zeroPrefixSampleCount == 0)
  }

  @Test("zero prefix is identical whole vs chunked (buffer boundaries must not matter)")
  func zeroPrefixSurvivesChunking() {
    var samples = [Float](repeating: 0, count: 7_777)
    samples.append(0.02)
    samples.append(contentsOf: [Float](repeating: 0.01, count: 500))
    let whole = ingestWhole(samples)
    let chunked = ingestChunked(samples, chunkSize: 513)  // deliberately not tile-aligned
    #expect(whole.zeroPrefixSampleCount == chunked.zeroPrefixSampleCount)
    #expect(whole.zeroPrefixSampleCount == 7_777)
  }

  // MARK: - #1788 sibling-threshold freeze

  /// THIS TEST EXISTS TO STOP A FUTURE MAINTAINER "HARMONISING" THE TWO THRESHOLDS.
  /// #1788 raises the all-zero-FROM-START ceiling on Bluetooth to 3.0s, and the two
  /// predicates now read as inconsistent — one takes a ceiling parameter, the other
  /// keeps a hard 1.0s. That is deliberate and they answer different questions:
  /// `isAllZeroFromStart` asks "did audio ever start" (Bluetooth negotiates, so it
  /// needs longer), while `isBecameZeroMidCapture` asks "did working audio DIE"
  /// (nothing negotiates mid-stream, so the longer bar would only delay a real
  /// failure the user is already living through).
  @Test("#1788: becameZeroMidCapture keeps 1.0s and ignores the all-zero ceiling")
  func becameZeroMidCaptureIsNotAffectedByTheCeiling() {
    var samples: [Float] = [0.5, 0.5, 0.5]  // meaningful signal first
    samples.append(
      contentsOf: [Float](repeating: 0, count: AudioConstants.minimumTranscriptionSamples))
    let detector = ingestWhole(samples)

    // Fires at 1.0s of trailing zeros, well under the 3.0s Bluetooth ceiling...
    #expect(detector.isBecameZeroMidCapture)
    // ...and passing that ceiling to the SIBLING predicate changes nothing here,
    // because real signal was seen, so `isAllZeroFromStart` is permanently false.
    #expect(
      !detector.isAllZeroFromStart(
        ceilingSamples: AudioConstants.bluetoothAllZeroMidTakeCeilingSamples))
    #expect(
      !detector.isAllZeroFromStart(ceilingSamples: AudioConstants.minimumTranscriptionSamples))
  }
}
