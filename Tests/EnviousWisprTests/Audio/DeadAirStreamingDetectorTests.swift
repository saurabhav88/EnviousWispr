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
    #expect(detector.isAllZeroFromStart)
    #expect(!detector.isBecameZeroMidCapture)
  }

  @Test("every sample exactly zero, BELOW threshold → not yet confident")
  func allZeroBelowThresholdNotYetConfident() {
    let detector = ingestWhole([Float](repeating: 0, count: threshold - 1))
    #expect(!detector.isAllZeroFromStart)
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
    #expect(!detector.isAllZeroFromStart)
    #expect(!detector.isBecameZeroMidCapture)
  }

  @Test("a single non-zero sample among zeros breaks allZeroFromStart")
  func oneNonZeroSampleBreaksAllZeroFromStart() {
    var samples = [Float](repeating: 0, count: threshold)
    samples[threshold / 2] = 0.01
    let detector = ingestWhole(samples)
    #expect(!detector.isAllZeroFromStart)
  }

  // MARK: - becameZeroMidCapture

  @Test("meaningful signal then a sustained zero suffix → becameZeroMidCapture")
  func meaningfulThenZeroBecomesMidCapture() {
    var samples = [Float](repeating: 0.1, count: 4_000)  // clearly above every floor
    samples.append(contentsOf: [Float](repeating: 0, count: threshold))
    let detector = ingestWhole(samples)
    #expect(detector.meaningfulSignalSeen)
    #expect(detector.isBecameZeroMidCapture)
    #expect(!detector.isAllZeroFromStart)
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
    #expect(detector.isAllZeroFromStart)
  }

  @Test("meaningful signal that never goes to zero triggers neither mode")
  func continuousSignalTriggersNeitherMode() {
    let detector = ingestWhole([Float](repeating: 0.1, count: threshold * 2))
    #expect(detector.meaningfulSignalSeen)
    #expect(!detector.isAllZeroFromStart)
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
    #expect(whole.isAllZeroFromStart == chunked.isAllZeroFromStart)
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
    #expect(whole.isAllZeroFromStart == chunked.isAllZeroFromStart)
    #expect(whole.isAllZeroFromStart)
  }
}
