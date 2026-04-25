import EnviousWisprCore
import Foundation

/// Shared utilities extracted from both pipelines to eliminate duplication.
internal enum SampleFilter {

  /// Filter audio samples using VAD speech segments, with padding and segment merging.
  /// Returns original samples if segments are empty or total voiced audio is below threshold.
  ///
  /// Extracted from TranscriptionPipeline.filterSamples() and WhisperKitPipeline.filterSamples()
  /// which were character-for-character identical.
  ///
  /// Hardened against unsorted input (#386) and `Int` overflow on near-`Int.max` endpoints (#387).
  /// Inputs may arrive in any order; output is monotonic by sample index and deduplicated by overlap.
  static func filter(
    from allSamples: [Float],
    segments: [SpeechSegment],
    padding: Int = 1600
  ) -> [Float] {
    guard !segments.isEmpty else { return allSamples }

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
    guard totalVoiced >= 4800 else { return allSamples }

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
    for range in merged {
      guard range.start < range.end else { continue }
      result.append(contentsOf: allSamples[range.start..<range.end])
    }
    return result.isEmpty ? allSamples : result
  }
}

/// Shared pipeline utilities.
internal enum PipelineUtils {

  /// Convert Duration to milliseconds for logging.
  static func durationMs(_ d: Duration) -> Int {
    let (seconds, attoseconds) = d.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}
