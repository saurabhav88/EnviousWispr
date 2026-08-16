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
  /// `shouldContinueDecoding` is polled by the decoder once per token; returning
  /// `false` stops that decode early and returns what it has.
  ///
  /// **This exists because a decode whose result is already discarded still
  /// costs the machine.** When a stop arrives mid-cycle the streaming loop drops
  /// its result (`finished`), but the transcribe itself ran to completion and
  /// contended with the authoritative decode that starts at that same moment —
  /// measured at 1.50x on the heart's own decode (#2108 Gate C). Aborting
  /// changes no output, only the compute.
  ///
  /// No defaulted parameter and no convenience overload: `noteStopRequested`
  /// (below) records what a defaulted async overload did to a concrete-typed
  /// call in #1309, and every call site here is better off stating whether its
  /// result is wanted.
  func transcribe(
    audioArray: [Float], decodeOptions: DecodingOptions?,
    shouldContinueDecoding: (@Sendable () -> Bool)?
  ) async throws -> [TranscriptionResult]
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
  package func transcribe(
    audioArray: [Float], decodeOptions: DecodingOptions?,
    shouldContinueDecoding: (@Sendable () -> Bool)?
  ) async throws -> [TranscriptionResult] {
    // WhisperKit's `TranscriptionCallback` is `(TranscriptionProgress) -> Bool?`,
    // polled per token in `TextDecoder.swift:735`; `false` breaks the token loop.
    // The progress payload is of no interest here — only whether to keep going —
    // so it is dropped rather than surfaced through the seam.
    // Written out rather than mapped: the closure's `Bool` -> `Bool?` widening
    // inside a `.map` defeats the type checker outright ("failed to produce
    // diagnostic for expression").
    var callback: TranscriptionCallback?
    if let keepGoing = shouldContinueDecoding {
      callback = { (_: TranscriptionProgress) -> Bool? in keepGoing() }
    }
    return try await self.transcribe(
      audioArray: audioArray, decodeOptions: decodeOptions, callback: callback,
      segmentCallback: nil)
  }

  package func encodeText(_ text: String) -> [Int] {
    // Leading space matters: OpenAI's reference transcribe.py tokenizes the
    // conditioning prompt as `" " + prompt.strip()` so the tokens land on the
    // space-prefixed BPE distribution the decoder was trained on (verified in
    // the prefill trace: words tokenize as `Ġ`-prefixed IDs with this form).
    tokenizer?.encode(text: " " + text.trimmingCharacters(in: .whitespaces)) ?? []
  }
}
