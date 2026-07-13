import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

@Suite("ASR empty result diagnostics")
struct ASREmptyResultDiagnosticsTests {

  @Test("Parakeet diagnostics include streaming and rescue fields without content")
  func parakeetDiagnosticsShape() {
    let diagnostics = ASREmptyResultDiagnostics(
      backend: "parakeet",
      mode: "streaming",
      hasSpeechEvidence: true,
      rawSampleCount: 19_200,
      vadSegmentCount: 1,
      vadSpeechDurationMs: 688,
      peakAudioLevel: 0.416,
      vadFilteredSampleCount: 11_008,
      finalSampleCount: 19_200,
      samplesPaddedToMinimum: false,
      usedRawFallbackAfterVAD: true,
      streamingResultChars: 0,
      streamingFinalizeFailed: false,
      streamingBuffersDispatched: 3,
      streamingBuffersFed: 3,
      batchRescueAttempted: true,
      batchRescueResultChars: 0,
      speechSegments: [SpeechSegment(startSample: 1_000, endSample: 12_000)]
    )

    let extra = diagnostics.sentryExtra()

    #expect(extra["backend"] as? String == "parakeet")
    #expect(extra["mode"] as? String == "streaming")
    #expect(extra["has_speech_evidence"] as? Bool == true)
    #expect(extra["asr.streaming_result_chars"] as? Int == 0)
    #expect(extra["asr.streaming_finalize_failed"] as? Bool == false)
    #expect(extra["asr.streaming_buffers_dispatched"] as? Int == 3)
    #expect(extra["asr.streaming_buffers_fed"] as? Int == 3)
    #expect(extra["asr.batch_rescue_attempted"] as? Bool == true)
    #expect(extra["asr.batch_rescue_result_chars"] as? Int == 0)
    #expect(extra["asr.vad_filtered_sample_count"] as? Int == 11_008)
    #expect(extra["asr.final_sample_count"] as? Int == 19_200)
    #expect(extra["asr.used_raw_fallback_after_vad"] as? Bool == true)
    #expect(extra["asr.samples_padded_to_minimum"] as? Bool == false)
    #expect(extra["asr.speech_segment_first_start_ms"] as? Int == 62)
    #expect(extra["asr.speech_segment_first_end_ms"] as? Int == 750)
    assertNoContentLikeKeys(extra)
  }

  @Test("#1523: a stamped channel count emits capture.native_channel_count; nil omits it")
  func channelCountEmitsOnASREmpty() {
    var diagnostics = ASREmptyResultDiagnostics(
      backend: "parakeet",
      mode: "streaming",
      hasSpeechEvidence: false,
      rawSampleCount: 0,
      vadSegmentCount: 0,
      vadSpeechDurationMs: 0,
      peakAudioLevel: 0.0
    )
    // Nil before the kernel stamps it → key absent.
    #expect(diagnostics.sentryExtra()["capture.native_channel_count"] == nil)

    diagnostics.captureNativeChannelCount = 2
    #expect(diagnostics.sentryExtra()["capture.native_channel_count"] as? Int == 2)
  }

  @Test("WhisperKit diagnostics keep comparable base fields and worker subset")
  func whisperKitDiagnosticsShape() {
    let diagnostics = ASREmptyResultDiagnostics(
      backend: "whisperKit",
      hasSpeechEvidence: true,
      rawSampleCount: 32_000,
      vadSegmentCount: 2,
      vadSpeechDurationMs: 1_500,
      peakAudioLevel: 0.3,
      vadFilteredSampleCount: 24_000,
      finalSampleCount: 32_000,
      samplesPaddedToMinimum: false,
      usedRawFallbackAfterVAD: false,
      batchRescueAttempted: true,
      batchRescueResultChars: 0,
      incrementalAccepted: false,
      incrementalResultChars: 0,
      incrementalDecodeCount: 2,
      incrementalSamplesCovered: 12_000,
      incrementalStrategy: "tail_empty_fallback",
      incrementalMode: "full",
      incrementalTailDecodeMs: 54,
      speechSegments: [
        SpeechSegment(startSample: 0, endSample: 8_000),
        SpeechSegment(startSample: 16_000, endSample: 32_000),
      ]
    )

    let extra = diagnostics.sentryExtra()

    #expect(extra["backend"] as? String == "whisperKit")
    #expect(extra["mode"] == nil)
    #expect(extra["asr.batch_rescue_attempted"] as? Bool == true)
    #expect(extra["asr.batch_rescue_result_chars"] as? Int == 0)
    #expect(extra["asr.incremental_accepted"] as? Bool == false)
    #expect(extra["asr.incremental_result_chars"] as? Int == 0)
    #expect(extra["asr.incremental_decode_count"] as? Int == 2)
    #expect(extra["asr.incremental_strategy"] as? String == "tail_empty_fallback")
    #expect(extra["asr.speech_segment_count"] as? Int == 2)
    #expect(extra["asr.speech_segment_first_start_ms"] as? Int == 0)
    #expect(extra["asr.speech_segment_first_end_ms"] as? Int == 500)
    #expect(extra["asr.speech_segment_last_start_ms"] as? Int == 1000)
    #expect(extra["asr.speech_segment_last_end_ms"] as? Int == 2000)
    assertNoContentLikeKeys(extra)
  }

  @Test("absorbAdapterDiagnostics copies the incremental-worker fields (Pass 2 r2 #B2)")
  func absorbCopiesIncrementalFields() {
    // The cutover dropped these before Sentry; this pins that the copy carries
    // every incremental field through to the rendered extra (parity with OLD
    // `WhisperKitPipeline.swift:1013-1017`).
    var diagnostics = ASREmptyResultDiagnostics(
      backend: "whisperKit",
      hasSpeechEvidence: true,
      rawSampleCount: 32_000,
      vadSegmentCount: 2,
      vadSpeechDurationMs: 1_500,
      peakAudioLevel: 0.3)
    var adapter = KernelASRAdapterDiagnostics()
    adapter.incrementalAccepted = true
    adapter.incrementalResultChars = 11
    adapter.incrementalDecodeCount = 3
    adapter.incrementalSamplesCovered = 20_000
    adapter.incrementalStrategy = "tail_streaming"
    adapter.incrementalMode = "full"
    adapter.incrementalTailDecodeMs = 42
    adapter.batchRescueAttempted = true

    diagnostics.absorbAdapterDiagnostics(adapter)
    let extra = diagnostics.sentryExtra()

    #expect(extra["asr.incremental_accepted"] as? Bool == true)
    #expect(extra["asr.incremental_result_chars"] as? Int == 11)
    #expect(extra["asr.incremental_decode_count"] as? Int == 3)
    #expect(extra["asr.incremental_samples_covered"] as? Int == 20_000)
    #expect(extra["asr.incremental_strategy"] as? String == "tail_streaming")
    #expect(extra["asr.incremental_mode"] as? String == "full")
    #expect(extra["asr.incremental_tail_decode_ms"] as? Int == 42)
    #expect(extra["asr.batch_rescue_attempted"] as? Bool == true)
  }

  @Test("batch diagnostics omit streaming fields")
  func batchDiagnosticsOmitStreamingFields() {
    let diagnostics = ASREmptyResultDiagnostics(
      backend: "parakeet",
      mode: "batch",
      hasSpeechEvidence: true,
      rawSampleCount: 24_000,
      vadSegmentCount: 1,
      vadSpeechDurationMs: 900,
      peakAudioLevel: 0.25,
      vadFilteredSampleCount: 18_000,
      finalSampleCount: 24_000,
      samplesPaddedToMinimum: false,
      usedRawFallbackAfterVAD: false,
      batchRescueAttempted: false,
      speechSegments: [SpeechSegment(startSample: 4_000, endSample: 12_000)]
    )

    let extra = diagnostics.sentryExtra()

    #expect(extra["backend"] as? String == "parakeet")
    #expect(extra["mode"] as? String == "batch")
    #expect(extra["asr.batch_rescue_attempted"] as? Bool == false)
    #expect(extra["asr.streaming_result_chars"] == nil)
    #expect(extra["asr.streaming_finalize_failed"] == nil)
    #expect(extra["asr.streaming_finalize_error_type"] == nil)
    #expect(extra["asr.streaming_buffers_dispatched"] == nil)
    #expect(extra["asr.streaming_buffers_fed"] == nil)
    assertNoContentLikeKeys(extra)
  }

  @Test("zero speech segments do not emit segment bounds")
  func zeroSpeechSegmentsDoNotEmitBounds() {
    let diagnostics = ASREmptyResultDiagnostics(
      backend: "parakeet",
      mode: "batch",
      hasSpeechEvidence: true,
      rawSampleCount: 16_000,
      vadSegmentCount: 0,
      vadSpeechDurationMs: 0,
      peakAudioLevel: 0.2,
      speechSegments: []
    )

    let extra = diagnostics.sentryExtra()

    #expect(extra["asr.speech_segment_count"] as? Int == 0)
    #expect(extra["asr.speech_segment_first_start_ms"] == nil)
    #expect(extra["asr.speech_segment_first_end_ms"] == nil)
    #expect(extra["asr.speech_segment_last_start_ms"] == nil)
    #expect(extra["asr.speech_segment_last_end_ms"] == nil)
    assertNoContentLikeKeys(extra)
  }

  @Test("single speech segment emits first bounds only")
  func singleSpeechSegmentEmitsFirstBoundsOnly() {
    let diagnostics = ASREmptyResultDiagnostics(
      backend: "parakeet",
      mode: "streaming",
      hasSpeechEvidence: true,
      rawSampleCount: 16_000,
      vadSegmentCount: 1,
      vadSpeechDurationMs: 500,
      peakAudioLevel: 0.2,
      speechSegments: [SpeechSegment(startSample: 2_000, endSample: 10_000)]
    )

    let extra = diagnostics.sentryExtra()

    #expect(extra["asr.speech_segment_count"] as? Int == 1)
    #expect(extra["asr.speech_segment_first_start_ms"] as? Int == 125)
    #expect(extra["asr.speech_segment_first_end_ms"] as? Int == 625)
    #expect(extra["asr.speech_segment_last_start_ms"] == nil)
    #expect(extra["asr.speech_segment_last_end_ms"] == nil)
    assertNoContentLikeKeys(extra)
  }

  private func assertNoContentLikeKeys(_ extra: [String: Any]) {
    for key in extra.keys {
      let lower = key.lowercased()
      #expect(!lower.contains("text"))
      #expect(!lower.contains("transcript"))
      #expect(!lower.contains("content"))
      #expect(!lower.contains("prompt"))
      #expect(!lower.contains("output"))
    }
  }
}
