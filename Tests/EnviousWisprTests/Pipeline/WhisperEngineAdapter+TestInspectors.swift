import EnviousWisprCore
@testable import EnviousWisprPipeline

// Test-only inspectors on the adapter. #4243: moved unchanged out of
// WhisperEngineAdapterTests.swift so the cloud critical bundle can compile
// WhisperEngineAdapterLastResultLifecycleTests without that whole suite.

extension WhisperEngineAdapter {
  var observedSpeechSegmentsForTests: [SpeechSegment] { observedSpeechSegmentsForUnitTests }

  /// Supply fixture-owned capture audio explicitly, as the kernel supplies
  /// `captureResult.samples` in production.
  func observeSpeechSegments(_ segments: [SpeechSegment], captureSamples: [Float]) {
    observeSpeechSegments(segments, rawCaptureSamples: captureSamples)
  }
}
