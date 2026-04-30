import EnviousWisprCore

/// Opaque handle to a WhisperKit-backed incremental transcription session.
///
/// Owned and vended by `WhisperKitBackend` via `makeIncrementalSession(options:)`.
/// Pipeline code drives the lifecycle (start → finalize or cancel) without
/// holding any WhisperKit-specific type.
///
/// This is the seam the R2 refactor (#360) introduces to remove three
/// cross-module reaches into `WhisperKitBackend`'s public surface:
/// - `whisperKitInstance` (dropped, was used to construct the worker directly)
/// - `whisperKitTokenizer` (dropped, was dead code in the worker)
/// - direct `WhisperKitIncrementalWorker` type reference in Pipeline
///
/// All three are replaced by `any WhisperKitIncrementalSession`. The full
/// boundary cleanup (Pipeline drops `import WhisperKit`, `Package.swift`
/// drops the WhisperKit dependency from the `EnviousWisprPipeline` target,
/// `WhisperKitBackend.whisperKitInstance`/`whisperKitTokenizer` go internal)
/// lands after the LanguageDetector reach also migrates — see plan §3.5
/// commit 3.
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
}
