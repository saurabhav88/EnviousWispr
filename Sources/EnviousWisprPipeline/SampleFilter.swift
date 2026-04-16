import EnviousWisprAudio
import EnviousWisprCore
import Foundation

/// Shared utilities extracted from both pipelines to eliminate duplication.
internal enum SampleFilter {

  /// Filter audio samples using VAD speech segments, with padding and segment merging.
  /// Returns original samples if segments are empty or total voiced audio is below threshold.
  ///
  /// Extracted from TranscriptionPipeline.filterSamples() and WhisperKitPipeline.filterSamples()
  /// which were character-for-character identical.
  static func filter(
    from allSamples: [Float],
    segments: [SpeechSegment],
    padding: Int = 1600
  ) -> [Float] {
    guard !segments.isEmpty else { return allSamples }

    let totalVoiced = segments.reduce(0) { $0 + ($1.endSample - $1.startSample) }
    guard totalVoiced >= 4800 else { return allSamples }

    var merged: [(start: Int, end: Int)] = []
    for segment in segments {
      let start = max(0, segment.startSample - padding)
      let end = min(allSamples.count, segment.endSample + padding)
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
