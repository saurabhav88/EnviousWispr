import EnviousWisprCore
import Foundation
@preconcurrency import WhisperKit

/// Narrow seam over WhisperKit's transcribe entry point, mirroring
/// `WhisperBackendDriving`. Lets the streaming session be
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

/// #2787: counts every decode the streaming session issues against the shared
/// `VendorDecodeOccupancy`, so a session that stops waiting mid-stream leaves
/// the engine visibly busy until WhisperKit actually returns. Wraps the
/// decoder INTERFACE rather than each call site: the streaming loop and both
/// flush branches go through one `transcribe`, and any future call the
/// session adds is counted by construction.
package struct OccupiedWhisperKitDecoder: WhisperKitTranscribing {
  let base: any WhisperKitTranscribing
  let occupancy: VendorDecodeOccupancy
  /// #3546 §3.7 T1: observation only, called synchronously immediately before each vendor
  /// decode this decorator issues (every streaming cycle, tail and flush decode passes
  /// through here), after a cancellation check.
  let onDecode: ASRInferenceEntryObserver?

  package init(
    base: any WhisperKitTranscribing, occupancy: VendorDecodeOccupancy,
    onDecode: ASRInferenceEntryObserver? = nil
  ) {
    self.base = base
    self.occupancy = occupancy
    self.onDecode = onDecode
  }

  package func transcribe(
    audioArray: [Float], decodeOptions: DecodingOptions?,
    shouldContinueDecoding: (@Sendable () -> Bool)?
  ) async throws -> [TranscriptionResult] {
    try await occupancy.track {
      try Task.checkCancellation()
      onDecode?()
      return try await base.transcribe(
        audioArray: audioArray, decodeOptions: decodeOptions,
        shouldContinueDecoding: shouldContinueDecoding)
    }
  }

  package func encodeText(_ text: String) -> [Int] { base.encodeText(text) }
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
