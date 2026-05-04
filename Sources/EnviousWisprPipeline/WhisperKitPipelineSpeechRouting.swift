import EnviousWisprCore
import Foundation

internal enum WhisperKitPipelineSpeechRouting {
  static func hasSpeechEvidence(vadSegments: [SpeechSegment]?) -> Bool {
    vadSegments.map { !$0.isEmpty } ?? true
  }

  static func paddedASRSamples(
    rawSamples: [Float],
    minimumSamples: Int = AudioConstants.minimumTranscriptionSamples
  ) -> [Float] {
    padIfShort(rawSamples, minimumSamples: minimumSamples)
  }

  static func paddedLIDSamples(
    filteredSamples: [Float],
    rawSamples: [Float],
    minimumSamples: Int = AudioConstants.minimumTranscriptionSamples
  ) -> [Float] {
    var samples = filteredSamples
    if samples.count < minimumSamples && rawSamples.count >= minimumSamples {
      samples = rawSamples
    }
    return padIfShort(samples, minimumSamples: minimumSamples)
  }

  static func lidWindowCount(forVoicedDuration voicedDuration: TimeInterval) -> Int {
    voicedDuration < LanguageDetectorThresholds.singleWindowMaxSec ? 1 : 4
  }

  static func transcriptionOptions(
    from base: TranscriptionOptions,
    speechSegments: [SpeechSegment]
  ) -> TranscriptionOptions {
    TranscriptionOptions(
      language: base.language,
      enableTimestamps: base.enableTimestamps,
      speechSegments: speechSegments
    )
  }

  private static func padIfShort(
    _ samples: [Float],
    minimumSamples: Int
  ) -> [Float] {
    guard samples.count > 0 && samples.count < minimumSamples else { return samples }
    return samples + [Float](repeating: 0, count: minimumSamples - samples.count)
  }
}
