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
      SpeechSegment(startSample: 1_000, endSample: 5_799)  // 4_799 voiced samples
    ]

    let result = SampleFilter.filter(from: samples, segments: segments)

    #expect(result == samples)
  }

  @Test("filters when total voiced audio is exactly the minimum threshold")
  func filtersAtMinimumVoicedThreshold() {
    let samples = (0..<12_000).map(Float.init)
    let segments = [
      SpeechSegment(startSample: 2_000, endSample: 6_800)  // exactly 4_800 voiced samples
    ]

    let result = SampleFilter.filter(from: samples, segments: segments, padding: 100)
    let expected = Array(samples[1_900..<6_900])

    #expect(result == expected)
  }

  @Test("clamps padded ranges to the available sample bounds")
  func clampsPaddedRangesToArrayBounds() {
    let samples = (0..<8_000).map(Float.init)
    let segments = [
      SpeechSegment(startSample: 500, endSample: 7_500)
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
      SpeechSegment(startSample: 7_000, endSample: 13_000)
    ]

    let result = SampleFilter.filter(from: samples, segments: segments)

    #expect(result == samples)
  }

  // MARK: - Hardening contract tests (#386 + #387 + adjacent overflow guards)

  @Test("unsorted segments produce the same output as sorted segments")
  func unsortedSegmentsProduceSameOutputAsSorted() {
    let samples = (0..<20_000).map(Float.init)
    let sorted = [
      SpeechSegment(startSample: 2_000, endSample: 5_000),
      SpeechSegment(startSample: 6_000, endSample: 8_000),
      SpeechSegment(startSample: 10_000, endSample: 13_000),
    ]
    let shuffled = [
      SpeechSegment(startSample: 10_000, endSample: 13_000),
      SpeechSegment(startSample: 2_000, endSample: 5_000),
      SpeechSegment(startSample: 6_000, endSample: 8_000),
    ]

    let sortedResult = SampleFilter.filter(from: samples, segments: sorted, padding: 500)
    let shuffledResult = SampleFilter.filter(from: samples, segments: shuffled, padding: 500)

    #expect(shuffledResult == sortedResult)
    // Guard against the trivial fallback: must not equal the entire input.
    #expect(shuffledResult != samples)
  }

  @Test("unsorted segments are deduplicated across overlap")
  func unsortedSegmentsAreDeduplicatedAcrossOverlap() {
    let samples = (0..<20_000).map(Float.init)
    let shuffled = [
      SpeechSegment(startSample: 9_000, endSample: 12_000),
      SpeechSegment(startSample: 5_000, endSample: 8_000),
    ]

    let result = SampleFilter.filter(from: samples, segments: shuffled, padding: 1_600)
    let expected = Array(samples[3_400..<13_600])

    #expect(result == expected)
  }

  @Test("nested segments merge into a single range")
  func nestedSegmentsMergeIntoSingleRange() {
    let samples = (0..<15_000).map(Float.init)
    let segments = [
      SpeechSegment(startSample: 1_000, endSample: 9_000),
      SpeechSegment(startSample: 3_000, endSample: 4_000),
    ]

    let result = SampleFilter.filter(from: samples, segments: segments, padding: 500)
    let expected = Array(samples[500..<9_500])

    #expect(result == expected)
  }

  @Test("endSample near Int.max does not trap and clamps to allSamples.count")
  func endSampleNearIntMaxDoesNotTrap() {
    let samples = (0..<10_000).map(Float.init)
    let segments = [
      SpeechSegment(startSample: 3_000, endSample: Int.max - 100)
    ]

    let result = SampleFilter.filter(from: samples, segments: segments, padding: 1_600)
    let expected = Array(samples[1_400..<10_000])

    #expect(result == expected)
  }

  @Test("negative padding is treated as zero padding")
  func negativePaddingClampsToZero() {
    let samples = (0..<20_000).map(Float.init)
    let segments = [
      SpeechSegment(startSample: 5_000, endSample: 8_000),
      SpeechSegment(startSample: 12_000, endSample: 15_000),
    ]

    let negative = SampleFilter.filter(from: samples, segments: segments, padding: -500)
    let zero = SampleFilter.filter(from: samples, segments: segments, padding: 0)

    #expect(negative == zero)
    #expect(negative != samples)
  }

  @Test("invalid segments mixed with valid speech are skipped in the merge loop too")
  func invalidSegmentsAreSkippedInMergeLoop() {
    // One valid 4_800-sample segment passes the voiced threshold.
    // One malformed segment (end <= start) sits at sample 10_000.
    // The merge loop must NOT emit a padded slice around the invalid
    // segment's reversed range — otherwise non-speech audio leaks through.
    let samples = (0..<20_000).map(Float.init)
    let segments = [
      SpeechSegment(startSample: 1_000, endSample: 5_800),
      SpeechSegment(startSample: 10_000, endSample: 9_000),
    ]

    let result = SampleFilter.filter(from: samples, segments: segments, padding: 500)
    let expected = Array(samples[500..<6_300])

    #expect(result == expected)
  }

  @Test("invalid segments (endSample <= startSample) do not contribute to voiced threshold")
  func invalidSegmentsAreSkippedInVoicedSum() {
    let samples = (0..<20_000).map(Float.init)
    // Three segments that are all invalid (endSample <= startSample).
    // Cumulative voiced length = 0; below the 4_800 threshold; expect allSamples back.
    let segments = [
      SpeechSegment(startSample: 5_000, endSample: 5_000),
      SpeechSegment(startSample: 8_000, endSample: 7_000),
      SpeechSegment(startSample: 12_000, endSample: 12_000),
    ]

    let result = SampleFilter.filter(from: samples, segments: segments)

    #expect(result == samples)
  }
}
