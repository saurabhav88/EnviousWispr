import EnviousWisprCore
import Testing

@testable import EnviousWisprPipeline

@Suite("KernelDictationDriver speech-segment routing")
struct WhisperKitPipelineSpeechSegmentsTests {
  @Test("pipeline passes speech segments to backend options")
  func pipelinePassesSpeechSegmentsToBackend() {
    let segments = [
      SpeechSegment(startSample: 1_000, endSample: 8_000),
      SpeechSegment(startSample: 12_000, endSample: 18_000),
    ]
    let base = TranscriptionOptions(language: "en", enableTimestamps: false)

    let options = WhisperKitPipelineSpeechRouting.transcriptionOptions(
      from: base,
      speechSegments: segments
    )

    #expect(options.language == "en")
    #expect(options.enableTimestamps == false)
    #expect(options.speechSegments.map(\.startSample) == [1_000, 12_000])
    #expect(options.speechSegments.map(\.endSample) == [8_000, 18_000])
  }

  @Test("VAD gate still fires on zero segments")
  func vadGateStillFires_onZeroSegments() {
    #expect(WhisperKitPipelineSpeechRouting.hasSpeechEvidence(vadSegments: []) == false)
    #expect(WhisperKitPipelineSpeechRouting.hasSpeechEvidence(vadSegments: nil) == true)
  }

  @Test("LID samples unchanged when ASR samples are raw")
  func lidSamplesUnchanged_whenAsrSamplesAreRaw() {
    // Pick a voiced range comfortably above minimumTranscriptionSamples
    // so paddedLIDSamples does NOT fall back to raw substitution
    // (which is its documented behavior when filtered audio is too short to drive LID).
    let rawSamples = Array(repeating: Float(0.25), count: 60_000)
    let voicedStart = 8_000
    let voicedEnd = voicedStart + AudioConstants.minimumTranscriptionSamples + 4_000  // > minimum
    let speechSegments = [SpeechSegment(startSample: voicedStart, endSample: voicedEnd)]
    let expectedLIDSamples = SampleFilter.filter(from: rawSamples, segments: speechSegments)

    let asrSamples = WhisperKitPipelineSpeechRouting.paddedASRSamples(
      rawSamples: rawSamples,
      minimumSamples: AudioConstants.minimumTranscriptionSamples
    )
    let lidSamples = WhisperKitPipelineSpeechRouting.paddedLIDSamples(
      filteredSamples: expectedLIDSamples,
      rawSamples: rawSamples,
      minimumSamples: AudioConstants.minimumTranscriptionSamples
    )

    #expect(asrSamples.count == rawSamples.count)
    #expect(lidSamples == expectedLIDSamples)
    #expect(lidSamples.count < asrSamples.count)
  }

  @Test("LID window routing uses one window below 3 seconds")
  func lidWindowCountUsesSingleWindowForShortClips() {
    for duration in [0.5, 1.0, 2.5, 2.99] {
      #expect(WhisperKitPipelineSpeechRouting.lidWindowCount(forVoicedDuration: duration) == 1)
    }
  }

  @Test("LID window routing uses four windows at and above 3 seconds")
  func lidWindowCountUsesFourWindowsForNormalClips() {
    for duration in [3.0, 5.0, 15.0] {
      #expect(WhisperKitPipelineSpeechRouting.lidWindowCount(forVoicedDuration: duration) == 4)
    }
  }
}
