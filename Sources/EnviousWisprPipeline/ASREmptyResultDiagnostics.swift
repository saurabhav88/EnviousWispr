import EnviousWisprCore
import Foundation

internal struct ASREmptyResultDiagnostics {
  var backend: String
  var mode: String?
  var hasSpeechEvidence: Bool
  var rawSampleCount: Int
  var vadSegmentCount: Int
  var vadSpeechDurationMs: Int
  var peakAudioLevel: Float

  var vadFilteredSampleCount: Int?
  var finalSampleCount: Int?
  var samplesPaddedToMinimum: Bool?
  var usedRawFallbackAfterVAD: Bool?

  var streamingResultChars: Int?
  var streamingFinalizeFailed: Bool?
  var streamingFinalizeErrorType: String?
  var streamingBuffersDispatched: Int?
  var streamingBuffersFed: Int?

  var batchRescueAttempted: Bool?
  var batchRescueResultChars: Int?

  var incrementalAccepted: Bool?
  var incrementalResultChars: Int?
  var incrementalDecodeCount: Int?
  var incrementalSamplesCovered: Int?
  var incrementalStrategy: String?
  var incrementalMode: String?
  var incrementalTailDecodeMs: Int?

  var speechSegments: [SpeechSegment] = []

  func sentryExtra() -> [String: Any] {
    var extra: [String: Any] = [
      "backend": backend,
      "has_speech_evidence": hasSpeechEvidence,
      "raw_sample_count": rawSampleCount,
      "vad_segment_count": vadSegmentCount,
      "vad_speech_duration_ms": vadSpeechDurationMs,
      "peak_audio_level": peakAudioLevel,
      "asr.speech_segment_count": vadSegmentCount,
    ]

    if let mode {
      extra["mode"] = mode
    }
    put(vadFilteredSampleCount, key: "asr.vad_filtered_sample_count", into: &extra)
    put(finalSampleCount, key: "asr.final_sample_count", into: &extra)
    put(samplesPaddedToMinimum, key: "asr.samples_padded_to_minimum", into: &extra)
    put(usedRawFallbackAfterVAD, key: "asr.used_raw_fallback_after_vad", into: &extra)

    put(streamingResultChars, key: "asr.streaming_result_chars", into: &extra)
    put(streamingFinalizeFailed, key: "asr.streaming_finalize_failed", into: &extra)
    put(streamingFinalizeErrorType, key: "asr.streaming_finalize_error_type", into: &extra)
    put(streamingBuffersDispatched, key: "asr.streaming_buffers_dispatched", into: &extra)
    put(streamingBuffersFed, key: "asr.streaming_buffers_fed", into: &extra)

    put(batchRescueAttempted, key: "asr.batch_rescue_attempted", into: &extra)
    put(batchRescueResultChars, key: "asr.batch_rescue_result_chars", into: &extra)

    put(incrementalAccepted, key: "asr.incremental_accepted", into: &extra)
    put(incrementalResultChars, key: "asr.incremental_result_chars", into: &extra)
    put(incrementalDecodeCount, key: "asr.incremental_decode_count", into: &extra)
    put(incrementalSamplesCovered, key: "asr.incremental_samples_covered", into: &extra)
    put(incrementalStrategy, key: "asr.incremental_strategy", into: &extra)
    put(incrementalMode, key: "asr.incremental_mode", into: &extra)
    put(incrementalTailDecodeMs, key: "asr.incremental_tail_decode_ms", into: &extra)

    addSpeechSegmentBounds(to: &extra)
    return extra
  }

  private func addSpeechSegmentBounds(to extra: inout [String: Any]) {
    guard let first = speechSegments.first else { return }
    extra["asr.speech_segment_first_start_ms"] = samplesToMs(first.startSample)
    extra["asr.speech_segment_first_end_ms"] = samplesToMs(first.endSample)

    if let last = speechSegments.last, speechSegments.count > 1 {
      extra["asr.speech_segment_last_start_ms"] = samplesToMs(last.startSample)
      extra["asr.speech_segment_last_end_ms"] = samplesToMs(last.endSample)
    }
  }

  private func samplesToMs(_ samples: Int) -> Int {
    Int(Double(samples) * 1000 / AudioConstants.sampleRate)
  }

  private func put<T>(_ value: T?, key: String, into extra: inout [String: Any]) {
    guard let value else { return }
    extra[key] = value
  }
}
