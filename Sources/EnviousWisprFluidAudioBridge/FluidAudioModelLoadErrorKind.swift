@preconcurrency import FluidAudio

/// #1525 PR I-B: classifies FluidAudio's raw model-load errors (`ParakeetBackend.prepare`,
/// not the transcribe path — see `FluidAudioASRErrorKind`). Three separate, unrelated
/// FluidAudio error enums can escape model loading; each needs its own `as?` probe.
/// `AsrModelsError.modelNotFound`/`.downloadFailed` and
/// `HuggingFaceDownloadError.modelNotFound`/`.downloadFailed` collide by case NAME
/// across enums (different payloads), so every case below is prefixed by its source enum.
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
  if let e = error as? DownloadUtils.OfflineError {
    switch e {
    case .networkDisabled: return .offlineNetworkDisabled(description)
    case .modelMissing: return .offlineModelMissing(description)
    @unknown default: return .unknownLoadFailure(description)
    }
  }
  if let e = error as? DownloadUtils.HuggingFaceDownloadError {
    switch e {
    case .invalidResponse: return .hfInvalidResponse(description)
    case .rateLimited: return .hfRateLimited(description)
    case .downloadFailed: return .hfDownloadFailed(description)
    case .modelNotFound: return .hfModelNotFound(description)
    case .htmlErrorResponse: return .hfHtmlErrorResponse(description)
    @unknown default: return .unknownLoadFailure(description)
    }
  }
  return nil  // none of the 3 named vendor types — caller maps this to .unknownLoadFailure too
}
