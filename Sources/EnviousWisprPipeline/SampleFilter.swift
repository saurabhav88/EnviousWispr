import EnviousWisprCore
import Foundation

/// Shared utilities extracted from both pipelines to eliminate duplication.
internal enum SampleFilter {

  /// Filter audio samples using VAD speech segments, with padding and segment merging.
  /// Returns original samples if segments are empty or total voiced audio is below threshold.
  ///
  /// Extracted from the old Parakeet pipeline.filterSamples() and WhisperKitPipeline.filterSamples()
  /// which were character-for-character identical.
  ///
  /// Hardened against unsorted input (#386) and `Int` overflow on near-`Int.max` endpoints (#387).
  /// Inputs may arrive in any order; output is monotonic by sample index and deduplicated by overlap.
  static func filter(
    from allSamples: [Float],
    segments: [SpeechSegment],
    padding: Int = AudioConstants.speechPaddingSamples
  ) -> [Float] {
    filterMapped(from: allSamples, segments: segments, padding: padding).samples
  }

  /// The filter's output with the place each kept stretch came from (#3147 §3.2).
  struct Filtered: Equatable, Sendable {
    /// Exactly what `filter` returns.
    let samples: [Float]
    /// One span per kept stretch, ascending: `decodeRange` indexes `samples`,
    /// `recordingStartSample` is where that stretch starts in the input. A passthrough is one
    /// span over everything; empty only for empty input.
    let timeline: [DictationAudioTimelineSpan]
  }

  /// `filter`, also returning the sample map. Built from the SAME merged ranges that copy the
  /// samples, in the same loop, so the map can never describe audio the filter did not keep.
  static func filterMapped(
    from allSamples: [Float],
    segments: [SpeechSegment],
    padding: Int = AudioConstants.speechPaddingSamples
  ) -> Filtered {
    let passthrough = Filtered(
      samples: allSamples, timeline: identityTimeline(sampleCount: allSamples.count))
    guard !segments.isEmpty else { return passthrough }

    let sampleCount = allSamples.count
    let pad = max(0, padding)
    let sortedSegments = segments.sorted { $0.startSample < $1.startSample }

    var totalVoiced = 0
    for segment in sortedSegments {
      guard segment.endSample > segment.startSample else { continue }
      let (length, lengthOverflow) =
        segment.endSample.subtractingReportingOverflow(segment.startSample)
      if lengthOverflow {
        totalVoiced = 4800
        break
      }
      let (newTotal, sumOverflow) = totalVoiced.addingReportingOverflow(length)
      if sumOverflow || newTotal >= 4800 {
        totalVoiced = 4800
        break
      }
      totalVoiced = newTotal
    }
    guard totalVoiced >= 4800 else { return passthrough }

    var merged: [(start: Int, end: Int)] = []
    for segment in sortedSegments {
      // Skip malformed segments (endSample <= startSample) consistently:
      // the voiced-sum accumulator above already ignores them, so the merge
      // loop must too. Otherwise, a single invalid segment alongside enough
      // valid speech to pass the threshold would emit a padded non-speech
      // slice in the filtered audio.
      guard segment.endSample > segment.startSample else { continue }

      let start: Int
      if segment.startSample <= pad {
        start = 0
      } else {
        start = min(sampleCount, segment.startSample - pad)
      }

      let (paddedEnd, endOverflow) = segment.endSample.addingReportingOverflow(pad)
      let end = endOverflow ? sampleCount : min(sampleCount, max(0, paddedEnd))

      if let last = merged.last, start <= last.end {
        merged[merged.count - 1].end = max(last.end, end)
      } else {
        merged.append((start, end))
      }
    }

    var result: [Float] = []
    var timeline: [DictationAudioTimelineSpan] = []
    for range in merged {
      guard range.start < range.end else { continue }
      timeline.append(
        DictationAudioTimelineSpan(
          decodeRange: result.count..<(result.count + range.end - range.start),
          recordingStartSample: range.start))
      result.append(contentsOf: allSamples[range.start..<range.end])
    }
    return result.isEmpty ? passthrough : Filtered(samples: result, timeline: timeline)
  }

  /// The map of audio decoded as captured: one span from sample 0, none for empty audio.
  static func identityTimeline(sampleCount: Int) -> [DictationAudioTimelineSpan] {
    sampleCount > 0
      ? [DictationAudioTimelineSpan(decodeRange: 0..<sampleCount, recordingStartSample: 0)] : []
  }
}
