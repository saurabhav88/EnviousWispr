
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

@Suite("SampleFilter")
struct SampleFilterTests {

  @Test("returns original samples when no speech segments are present")
  func returnsOriginalSamplesWhenSegmentsAreEmpty() {
    let samples: [Float] = [0, 1, 2, 3, 4]

    let result = SampleFilter.filter(from: samples, segments: [])

    #expect(result == samples)
  }

  @Test("returns original samples when total voiced audio is below the minimum threshold")
  func returnsOriginalSamplesBelowVoicedThreshold() {
    let samples = (0..<10_000).map(Float.init)
    let segments = [
      SpeechSegment(startSample: 1_000, endSample: 5_799),  // 4_799 voiced samples
    ]

    let result = SampleFilter.filter(from: samples, segments: segments)

    #expect(result == samples)
  }

  @Test("filters when total voiced audio is exactly the minimum threshold")
  func filtersAtMinimumVoicedThreshold() {
    let samples = (0..<12_000).map(Float.init)
    let segments = [
      SpeechSegment(startSample: 2_000, endSample: 6_800),  // exactly 4_800 voiced samples
    ]

    let result = SampleFilter.filter(from: samples, segments: segments, padding: 100)
    let expected = Array(samples[1_900..<6_900])

    #expect(result == expected)
  }

  @Test("clamps padded ranges to the available sample bounds")
  func clampsPaddedRangesToArrayBounds() {
    let samples = (0..<8_000).map(Float.init)
    let segments = [
      SpeechSegment(startSample: 500, endSample: 7_500),
    ]

    let result = SampleFilter.filter(from: samples, segments: segments, padding: 2_000)

    #expect(result == samples)
  }

  @Test("merges overlapping padded ranges into one contiguous slice")
  func mergesOverlappingPaddedRanges() {
    let samples = (0..<20_000).map(Float.init)
    let segments = [
      SpeechSegment(startSample: 5_000, endSample: 8_000),
      SpeechSegment(startSample: 9_000, endSample: 12_000),
    ]

    let result = SampleFilter.filter(from: samples, segments: segments, padding: 1_600)
    let expected = Array(samples[3_400..<13_600])

    #expect(result == expected)
  }

  @Test("merges padded ranges that only touch at the boundary")
  func mergesTouchingPaddedRanges() {
    let samples = (0..<13_000).map(Float.init)
    let segments = [
      SpeechSegment(startSample: 2_000, endSample: 4_400),
      SpeechSegment(startSample: 7_600, endSample: 10_000),
    ]

    let result = SampleFilter.filter(from: samples, segments: segments, padding: 1_600)
    let expected = Array(samples[400..<11_600])

    #expect(result == expected)
  }

  @Test("keeps disjoint padded ranges separate and concatenates them in segment order")
  func keepsDisjointRangesSeparate() {
    let samples = (0..<16_000).map(Float.init)
    let segments = [
      SpeechSegment(startSample: 2_000, endSample: 5_000),
      SpeechSegment(startSample: 10_000, endSample: 13_000),
    ]

    let result = SampleFilter.filter(from: samples, segments: segments, padding: 500)
    let expected = Array(samples[1_500..<5_500]) + Array(samples[9_500..<13_500])

    #expect(result == expected)
  }

  @Test("returns original samples when every padded range is invalid after clamping")
  func returnsOriginalSamplesWhenAllRangesBecomeInvalid() {
    let samples = (0..<1_000).map(Float.init)
    let segments = [
      SpeechSegment(startSample: 7_000, endSample: 13_000),
    ]

    let result = SampleFilter.filter(from: samples, segments: segments)

    #expect(result == samples)
  }

  // TODO: production bug — add a contract test once fixed.
  // `SampleFilter.filter` assumes `segments` are already sorted by `startSample`.
  // With unsorted segments, the merge path can keep the later start and drop the
  // earlier one because it only extends `last.end`, never rewrites `last.start`.
}