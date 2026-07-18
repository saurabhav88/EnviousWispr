@preconcurrency import FluidAudio

/// #1525 PR I-B: classifies FluidAudio's raw `ASRError` (transcription path) into a
/// plain, name-collision-free value. This target exists because `FluidAudio` exports
/// a struct literally named `FluidAudio` that shadows module-qualified lookup, and a
/// bare unqualified `ASRError` inside `EnviousWisprASR` silently resolves to the app's
/// OWN `ASRError` type instead (`swift-patterns.md` RULE: fluidaudio-unqualified-symbols) —
/// this is the one module that safely names FluidAudio's own `ASRError`.
package enum FluidAudioASRErrorKind: Sendable, Equatable {
  case notInitialized(String)
  case invalidAudioData(String)
  case modelLoadFailed(String)
  case processingFailed(String)
  case modelCompilationFailed(String)
  case unsupportedPlatform(String)
  case streamingConversionFailed(String)
  case fileAccessFailed(String)
  case unknownFutureCase(String)
}

package func classifyFluidAudioASRError(_ error: any Error) -> FluidAudioASRErrorKind? {
  guard let error = error as? ASRError else { return nil }  // unambiguous here: this module declares no other ASRError
  let description = error.localizedDescription
  switch error {
  case .notInitialized: return .notInitialized(description)
  case .invalidAudioData: return .invalidAudioData(description)
  case .modelLoadFailed: return .modelLoadFailed(description)
  case .processingFailed: return .processingFailed(description)
  case .modelCompilationFailed: return .modelCompilationFailed(description)
  case .unsupportedPlatform: return .unsupportedPlatform(description)
  case .streamingConversionFailed: return .streamingConversionFailed(description)
  case .fileAccessFailed: return .fileAccessFailed(description)
  @unknown default: return .unknownFutureCase(description)
  }
}
