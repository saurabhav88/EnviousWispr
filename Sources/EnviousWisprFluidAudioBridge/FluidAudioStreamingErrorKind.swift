@preconcurrency import FluidAudio

/// #1654: the inner cause carried by `allWindowsFailed`, as a BARE semantic case.
///
/// Deliberately payload-free: the vendor's inner error is arbitrary text and must not
/// cross this boundary. This answers "why did every window fail" and nothing else.
package enum FluidAudioStreamingInnerCause: Sendable, Equatable {
  case notInitialized
  case invalidAudioData
  case modelLoadFailed
  case processingFailed
  case modelCompilationFailed
  case unsupportedPlatform
  case streamingConversionFailed
  case fileAccessFailed
  /// Added by the vendor in the 2026-08-08 pin bump (#1985, `afb9aab` -> `a1767d86`).
  case encoderInstantiationFailed
  case unknownFutureCase
}

/// #1654: classifies FluidAudio's raw `SlidingWindowAsrError` (streaming path) into a
/// plain, name-collision-free value, mirroring `FluidAudioASRErrorKind` for batch.
/// Same reason that target exists: `FluidAudio` exports a struct literally named
/// `FluidAudio`, so this is the one module that can safely name the vendor's types
/// (`swift-patterns.md` RULE: fluidaudio-unqualified-symbols).
///
/// **Carries NO vendor text, unlike the batch kind, and that difference is deliberate.**
/// The plan's privacy paragraph forbids forwarding the inner error of
/// `.modelProcessingFailed`. Reading the vendor's `errorDescription` at the shipped pin
/// shows the hazard is wider than the plan named: THREE cases interpolate an inner
/// error's `localizedDescription` into their own text —
/// `audioBufferProcessingFailed`, `audioConversionFailed` and `modelProcessingFailed`
/// (`SlidingWindowAsrSession.swift:173-179`) — and `invalidConfiguration` interpolates a
/// vendor-authored message. So taking the vendor description for ANY case risks
/// forwarding arbitrary vendor text, and the safe rule is to take it for none.
///
/// Identity lives in the case; the human-readable string is app-authored downstream.
///
/// All seven vendor cases are enumerated, including the six not reachable today.
/// Enumerating them costs nothing and means a dependency bump that starts producing one
/// yields a named identity instead of a generic bucket. Reachability is a property of
/// the VENDOR's code, not ours, so it must be re-verified on any FluidAudio pin bump —
/// and #2041 is what happens when nobody does.
package enum FluidAudioStreamingErrorKind: Sendable, Equatable {
  case modelsNotLoaded
  case streamAlreadyExists
  case audioBufferProcessingFailed
  case audioConversionFailed
  /// The vendor's `.modelProcessingFailed`, named for its MEANING rather than its
  /// spelling. Verified at the SHIPPED pin `a1767d86`, not the checkout on disk (which
  /// is a revision behind): it is constructed per failing window at
  /// `SlidingWindowAsrManager.swift:645`, but only ever THROWN at `:262`, guarded by
  /// `processedChunks == 0`. Reaching a caller therefore means every window failed,
  /// and the name saves each future reader from re-deriving that.
  ///
  /// `inner` is where the actual cause lives. The vendor always wraps rather than passes
  /// through, and there is no deeper chain, so it is unwrapped exactly once. A foreign
  /// inner error yields `nil` and the outer identity still stands: we know every window
  /// failed even when we cannot name why.
  case allWindowsFailed(inner: FluidAudioStreamingInnerCause?)
  case bufferOverflow
  case invalidConfiguration
  case unknownFutureCase
}

/// Maps the inner error of `.modelProcessingFailed` to a bare semantic cause.
/// Returns `nil` for anything that is not FluidAudio's own `ASRError`.
private func streamingInnerCause(_ error: any Error) -> FluidAudioStreamingInnerCause? {
  guard let error = error as? ASRError else { return nil }
  switch error {
  case .notInitialized: return .notInitialized
  case .invalidAudioData: return .invalidAudioData
  case .modelLoadFailed: return .modelLoadFailed
  case .processingFailed: return .processingFailed
  case .modelCompilationFailed: return .modelCompilationFailed
  case .unsupportedPlatform: return .unsupportedPlatform
  case .streamingConversionFailed: return .streamingConversionFailed
  case .fileAccessFailed: return .fileAccessFailed
  case .encoderInstantiationFailed: return .encoderInstantiationFailed
  @unknown default: return .unknownFutureCase
  }
}

package func classifyFluidAudioStreamingError(_ error: any Error) -> FluidAudioStreamingErrorKind? {
  // Unambiguous here: this module declares no other SlidingWindowAsrError.
  guard let error = error as? SlidingWindowAsrError else { return nil }
  switch error {
  case .modelsNotLoaded: return .modelsNotLoaded
  case .streamAlreadyExists: return .streamAlreadyExists
  case .audioBufferProcessingFailed: return .audioBufferProcessingFailed
  case .audioConversionFailed: return .audioConversionFailed
  case .modelProcessingFailed(let inner):
    return .allWindowsFailed(inner: streamingInnerCause(inner))
  case .bufferOverflow: return .bufferOverflow
  case .invalidConfiguration: return .invalidConfiguration
  @unknown default: return .unknownFutureCase
  }
}
