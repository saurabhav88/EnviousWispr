import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// #1317 / #4841 — the per-take exact-zero counter. Observation only since #4841:
// it feeds the silent-mic notice and the DEBUG zero-prefix diagnostic; exact
// zeros never end a take. Streaming, buffer-by-buffer, so the counts must not
// depend on where buffer boundaries fall.
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

  // MARK: - Trailing exact-zero run (#4841)

  @Test("the trailing run counts consecutive exact zeros and resets on any non-zero sample")
  func trailingRunCountsAndResets() {
    var samples = [Float](repeating: 0, count: 300)
    samples.append(0.01)
    samples.append(contentsOf: [Float](repeating: 0, count: 120))
    let detector = ingestWhole(samples)
    #expect(detector.totalSampleCount == 421)
    #expect(detector.consecutiveExactZeroSuffix == 120)
  }

  @Test("tiny non-zero noise is not an exact zero, so the run stays at zero")
  func tinyNoiseIsNotExactZero() {
    let detector = ingestWhole([Float](repeating: 1e-7, count: threshold))
    #expect(detector.consecutiveExactZeroSuffix == 0)
    #expect(detector.totalSampleCount == threshold)
  }

  @Test("an all-zero capture's run equals its whole length")
  func allZeroRunEqualsLength() {
    let detector = ingestWhole([Float](repeating: 0, count: threshold))
    #expect(detector.consecutiveExactZeroSuffix == detector.totalSampleCount)
  }

  @Test("counts are identical whole vs chunked across a run that straddles a buffer boundary")
  func countsSurviveChunking() {
    var samples = [Float](repeating: 0.05, count: 1_000)
    samples.append(contentsOf: [Float](repeating: 0, count: 2_500))
    for chunk in [1, 7, 333, 640, 1_001, 4_096] {
      let whole = ingestWhole(samples)
      let chunked = ingestChunked(samples, chunkSize: chunk)
      #expect(chunked.totalSampleCount == whole.totalSampleCount, "chunk \(chunk)")
      #expect(
        chunked.consecutiveExactZeroSuffix == whole.consecutiveExactZeroSuffix, "chunk \(chunk)")
      #expect(whole.consecutiveExactZeroSuffix == 2_500)
    }
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
}
