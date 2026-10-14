import EnviousWisprCore
import Foundation

/// Opaque handle to a Whisper incremental (Faster Transcription) session.
///
/// Vended by the Whisper backend via `makeStreamingSession(options:...)`: since #3735
/// `TranscribeCppRollingSession`; the retired `WhisperKitStreamingSession` still conforms
/// until WhisperKit is removed. Pipeline code drives the lifecycle (start → finalize or
/// cancel) without holding any engine-specific type.
///
/// This is the seam introduced by the R2 refactor (#360) so that the pipeline does not
/// import an engine package and does not reach into ASR-internal types. Conformers and the
/// protocol are `package`-access, confined to `EnviousWisprASR`.
package protocol WhisperIncrementalSession: Sendable {
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
  /// `finalize`, so state can change in between).
  ///
  /// Deliberately NO extension default: a defaulted async no-op plus a
  /// synchronous conformer implementation lets a concrete-typed `await`
  /// call resolve to the no-op instead of the conformer's method (Swift
  /// prefers the async overload in async contexts), silently dropping the
  /// snapshot — the #1309 flaky-test root cause. Conformers with nothing to
  /// snapshot implement an explicit `async` no-op.
  func noteStopRequested() async
}

// MARK: - Shared incremental-decode types (#1315: moved here when the
// text-stitch worker was deleted; the streaming sessions are the consumers).

package struct IncrementalResult: Sendable {
  package let text: String?
  package let samplesCovered: Int
  package let decodeCount: Int
  package let totalDecodeTimeMs: Int  // periphery:ignore - telemetry field, populated for diagnostics
  package let accepted: Bool
  package let strategy: String
  package let tailDecodeMs: Int
  /// #1309: a loop decode was still in flight when finalize/stop arrived.
  /// Telemetry metadata.
  package var stopWhileDecodeInFlight: Bool = false
}
