import EnviousWisprCore

/// Opaque handle to a WhisperKit-backed incremental transcription session.
///
/// Owned and vended by `WhisperKitBackend` via `makeIncrementalSession(options:)`.
/// Pipeline code drives the lifecycle (start → finalize or cancel) without
/// holding any WhisperKit-specific type.
///
/// This is the seam introduced by the R2 refactor (#360) so that
/// `WhisperKitPipeline` does not import the WhisperKit package and does not
/// reach into ASR-internal types. The conformer (`WhisperKitIncrementalWorker`)
/// is `package`-access; the protocol is `package`-access; both stay confined
/// to `EnviousWisprASR`.
package protocol WhisperKitIncrementalSession: Sendable {
  /// Begin background incremental decoding cycles. The provider closure is
  /// called periodically to fetch the growing audio buffer.
  func start(
    audioSamplesProvider: @Sendable @escaping () async -> (samples: [Float], count: Int)
  ) async

  /// Stop the incremental loop and produce the final result. `finalSamples`
  /// is the post-VAD audio and `speechSegments` are the VAD speech ranges.
  /// The session may apply tail-decode logic over the uncovered portion.
  func finalize(
    finalSamples: [Float],
    speechSegments: [SpeechSegment]
  ) async -> IncrementalResult

  /// Cancel the incremental loop without producing a result. Used on PTT
  /// cancel and on stop-recording-too-short paths.
  func cancel() async

  /// #1309: the user's stop arrived — snapshot any telemetry that must
  /// reflect the STOP moment (the adapter drains feed tasks before calling
  /// `finalize`, so state can change in between). Default no-op.
  func noteStopRequested() async
}

extension WhisperKitIncrementalSession {
  package func noteStopRequested() async {}
}
