@preconcurrency import FluidAudio

/// #1525 PR I-B (types updated #1981): classifies FluidAudio's raw model-load errors
/// (`ParakeetBackend.prepare`, not the transcribe path — see `FluidAudioASRErrorKind`).
/// Two vendor error enums can escape model loading: `AsrModelsError` and the unified
/// `DownloadError` (which absorbed the deleted `DownloadUtils.OfflineError` and
/// `DownloadUtils.HuggingFaceDownloadError` with case names preserved, plus two new
/// cases). `AsrModelsError.modelNotFound`/`.downloadFailed` and
/// `DownloadError.modelNotFound`/`.downloadFailed` collide by case NAME across enums
/// (different payloads), so every case below is prefixed by its historical source —
/// the `offline*`/`hf*` names are FROZEN identities predating the vendor unification.
package enum FluidAudioModelLoadErrorKind: Sendable, Equatable {
  case modelsModelNotFound(String)
  case modelsDownloadFailed(String)
  case modelsLoadingFailed(String)
  case modelsCompilationFailed(String)
  case offlineNetworkDisabled(String)
  case offlineModelMissing(String)
  case hfInvalidResponse(String)
  case hfRateLimited(String)
  case hfDownloadFailed(String)
  case hfModelNotFound(String)
  case hfHtmlErrorResponse(String)
  case downloadInvalidArtifact(String)
  case downloadStalled(String)
  case unknownLoadFailure(String)
}

package func classifyFluidAudioModelLoadError(_ error: any Error) -> FluidAudioModelLoadErrorKind? {
  let description = error.localizedDescription
  if let e = error as? AsrModelsError {
    switch e {
    case .modelNotFound: return .modelsModelNotFound(description)
    case .downloadFailed: return .modelsDownloadFailed(description)
    case .loadingFailed: return .modelsLoadingFailed(description)
    case .modelCompilationFailed: return .modelsCompilationFailed(description)
    @unknown default: return .unknownLoadFailure(description)
    }
  }
  if let e = error as? DownloadError {
    // Deliberately NO `default`/`@unknown default`: the fork compiles non-resilient,
    // so a future vendor case is a COMPILE error here, never a silent fallthrough
    // (#1981 chunk 2 invariant).
    switch e {
    case .networkDisabled: return .offlineNetworkDisabled(description)
    case .modelMissing: return .offlineModelMissing(description)
    case .invalidResponse: return .hfInvalidResponse(description)
    case .rateLimited: return .hfRateLimited(description)
    case .downloadFailed: return .hfDownloadFailed(description)
    case .modelNotFound: return .hfModelNotFound(description)
    case .htmlErrorResponse: return .hfHtmlErrorResponse(description)
    case .invalidArtifact: return .downloadInvalidArtifact(description)
    case .stalled: return .downloadStalled(description)
    }
  }
  return nil  // neither named vendor type — caller maps this to .unknownLoadFailure too
}
