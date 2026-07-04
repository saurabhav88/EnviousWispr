import EnviousWisprCore
import Foundation

@preconcurrency import WhisperKit

/// Opaque handle to a WhisperKit-backed incremental transcription session.
///
/// Owned and vended by `WhisperKitBackend` via `makeStreamingSession(options:)`.
/// Pipeline code drives the lifecycle (start → finalize or cancel) without
/// holding any WhisperKit-specific type.
///
/// This is the seam introduced by the R2 refactor (#360) so that
/// `WhisperKitPipeline` does not import the WhisperKit package and does not
/// reach into ASR-internal types. The conformer (`WhisperKitStreamingSession`)
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

// MARK: - Shared incremental-decode types (#1315: moved here when the
// text-stitch worker was deleted; the streaming session is the sole consumer).

package struct IncrementalResult: Sendable {
  package let text: String?
  package let samplesCovered: Int
  package let decodeCount: Int
  package let totalDecodeTimeMs: Int  // periphery:ignore - telemetry field, populated for diagnostics
  package let accepted: Bool
  package let mode: String
  package let strategy: String
  package let tailDecodeMs: Int
  /// #1309: a loop decode was still in flight when finalize/stop arrived.
  /// Telemetry metadata.
  package var stopWhileDecodeInFlight: Bool = false
}

/// Narrow seam over WhisperKit's transcribe entry point, mirroring
/// `WhisperKitBackendDriving`. Lets the streaming session be
/// characterization-tested with a fake decoder instead of a loaded model.
package protocol WhisperKitTranscribing: Sendable {
  func transcribe(audioArray: [Float], decodeOptions: DecodingOptions?) async throws
    -> [TranscriptionResult]
  /// Tokenize text into decoder token IDs for `DecodingOptions.promptTokens`
  /// (prior-text conditioning / `condition_on_previous_text`). Returns `[]` if the
  /// tokenizer is not loaded. Lets the streaming session feed the confirmed prefix
  /// as context on each decode so the model does not hallucinate a trailing
  /// "thank you" on a breath tail (#1276 investigation: decoding blind = the cause).
  func encodeText(_ text: String) -> [Int]
}

// Retroactive @unchecked Sendable: WhisperKit (upstream, @preconcurrency-imported)
// has mutable stored properties so it cannot auto-synthesize Sendable, but every
// caller of the shared instance in this package already goes through actor
// isolation (WhisperKitBackend) or the drain gate (`readyKitAfterWarmupDrain`)
// that serializes access when passing `WhisperKit` across actor boundaries
// under `@preconcurrency import WhisperKit`.
extension WhisperKit: @retroactive @unchecked Sendable {}

extension WhisperKit: WhisperKitTranscribing {
  // Explicit wrapper: WhisperKit's real `transcribe(audioArray:decodeOptions:callback:segmentCallback:)`
  // has two additional defaulted parameters, which structural witness matching
  // does not bridge automatically. Forward to it explicitly.
  package func transcribe(audioArray: [Float], decodeOptions: DecodingOptions?) async throws
    -> [TranscriptionResult]
  {
    try await self.transcribe(
      audioArray: audioArray, decodeOptions: decodeOptions, callback: nil, segmentCallback: nil)
  }

  package func encodeText(_ text: String) -> [Int] {
    // Leading space matters: OpenAI's reference transcribe.py tokenizes the
    // conditioning prompt as `" " + prompt.strip()` so the tokens land on the
    // space-prefixed BPE distribution the decoder was trained on (verified in
    // the prefill trace: words tokenize as `Ġ`-prefixed IDs with this form).
    tokenizer?.encode(text: " " + text.trimmingCharacters(in: .whitespaces)) ?? []
  }
}
