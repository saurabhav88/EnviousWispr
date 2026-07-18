import EnviousWisprCore
import EnviousWisprFluidAudioBridge
import Foundation

/// #1525 PR I-B: pinned Sentry identity for a raw throw out of `ParakeetBackend
/// .prepare`'s 3 FluidAudio model-load calls. Separate from `ParakeetTranscriptionSentryError`
/// — different physical failure class and Sentry category, same reasoning WhisperKit
/// load/decode stay separate from Parakeet transcription.
enum ParakeetModelLoadSentryError: Error, LocalizedError, CustomNSError, Sendable, Equatable {
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

  static let errorDomain = "EnviousWisprASR.ParakeetModelLoadSentryError"

  var errorCode: Int {
    switch self {
    case .modelsModelNotFound: return 0
    case .modelsDownloadFailed: return 1
    case .modelsLoadingFailed: return 2
    case .modelsCompilationFailed: return 3
    case .offlineNetworkDisabled: return 4
    case .offlineModelMissing: return 5
    case .hfInvalidResponse: return 6
    case .hfRateLimited: return 7
    case .hfDownloadFailed: return 8
    case .hfModelNotFound: return 9
    case .hfHtmlErrorResponse: return 10
    case .unknownLoadFailure: return 11
    }
  }

  var errorDescription: String? {
    switch self {
    case .modelsModelNotFound(let d), .modelsDownloadFailed(let d), .modelsLoadingFailed(let d),
      .modelsCompilationFailed(let d), .offlineNetworkDisabled(let d), .offlineModelMissing(let d),
      .hfInvalidResponse(let d), .hfRateLimited(let d), .hfDownloadFailed(let d),
      .hfModelNotFound(let d), .hfHtmlErrorResponse(let d), .unknownLoadFailure(let d):
      return d
    }
  }

  /// #1525 PR I-B (Codex cloud review): `CustomNSError`'s default `errorUserInfo`
  /// is empty, and an empty `userInfo` does not survive the XPC boundary's
  /// NSSecureCoding archive round-trip with `errorDescription` intact — the
  /// receiving process's `(error as NSError).localizedDescription` falls back to
  /// Foundation's generic "operation couldn't be completed" message. Populating
  /// `NSLocalizedDescriptionKey` here bakes the description directly into
  /// `userInfo`, which IS preserved through the round-trip (confirmed via a
  /// direct `NSKeyedArchiver`/`NSKeyedUnarchiver` probe this session).
  var errorUserInfo: [String: Any] {
    [NSLocalizedDescriptionKey: errorDescription ?? ""]
  }

  init(mapping kind: FluidAudioModelLoadErrorKind) {
    switch kind {
    case .modelsModelNotFound(let d): self = .modelsModelNotFound(d)
    case .modelsDownloadFailed(let d): self = .modelsDownloadFailed(d)
    case .modelsLoadingFailed(let d): self = .modelsLoadingFailed(d)
    case .modelsCompilationFailed(let d): self = .modelsCompilationFailed(d)
    case .offlineNetworkDisabled(let d): self = .offlineNetworkDisabled(d)
    case .offlineModelMissing(let d): self = .offlineModelMissing(d)
    case .hfInvalidResponse(let d): self = .hfInvalidResponse(d)
    case .hfRateLimited(let d): self = .hfRateLimited(d)
    case .hfDownloadFailed(let d): self = .hfDownloadFailed(d)
    case .hfModelNotFound(let d): self = .hfModelNotFound(d)
    case .hfHtmlErrorResponse(let d): self = .hfHtmlErrorResponse(d)
    case .unknownLoadFailure(let d): self = .unknownLoadFailure(d)
    }
  }

  /// The production catch site's actual normalization logic, extracted so it is
  /// directly testable — `ParakeetBackend` has no test-injection seam for model
  /// loading, so a test "recreating the same catch pattern" would test copied test
  /// code, not production.
  init(normalizingLoadError error: any Error) {
    if let kind = classifyFluidAudioModelLoadError(error) {
      self.init(mapping: kind)
    } else {
      self = .unknownLoadFailure(error.localizedDescription)
    }
  }

  /// Reconstructs the typed, conforming error from an NSError that survived the XPC
  /// round-trip. Returns `nil` if the domain doesn't match.
  init?(reconstructingFrom error: NSError) {
    guard error.domain == Self.errorDomain else { return nil }
    let d = error.localizedDescription
    switch error.code {
    case 0: self = .modelsModelNotFound(d)
    case 1: self = .modelsDownloadFailed(d)
    case 2: self = .modelsLoadingFailed(d)
    case 3: self = .modelsCompilationFailed(d)
    case 4: self = .offlineNetworkDisabled(d)
    case 5: self = .offlineModelMissing(d)
    case 6: self = .hfInvalidResponse(d)
    case 7: self = .hfRateLimited(d)
    case 8: self = .hfDownloadFailed(d)
    case 9: self = .hfModelNotFound(d)
    case 10: self = .hfHtmlErrorResponse(d)
    case 11: self = .unknownLoadFailure(d)
    default: return nil
    }
  }
}

extension ParakeetModelLoadSentryError: StableSentryErrorIdentity {
  var sentryFingerprintDescriptor: String {
    // No live Sentry measurement has been run against these case-level descriptors
    // yet (§3.5's "remaining work" — never distinctly constructed before this PR).
    // Every case below is a fresh, defensive pin.
    switch self {
    case .modelsModelNotFound: return "FluidAudio.AsrModelsError#0"
    case .modelsDownloadFailed: return "FluidAudio.AsrModelsError#1"
    case .modelsLoadingFailed: return "FluidAudio.AsrModelsError#2"
    case .modelsCompilationFailed: return "FluidAudio.AsrModelsError#3"
    case .offlineNetworkDisabled: return "FluidAudio.DownloadUtils.OfflineError#0"
    case .offlineModelMissing: return "FluidAudio.DownloadUtils.OfflineError#1"
    case .hfInvalidResponse: return "FluidAudio.DownloadUtils.HuggingFaceDownloadError#0"
    case .hfRateLimited: return "FluidAudio.DownloadUtils.HuggingFaceDownloadError#1"
    case .hfDownloadFailed: return "FluidAudio.DownloadUtils.HuggingFaceDownloadError#2"
    case .hfModelNotFound: return "FluidAudio.DownloadUtils.HuggingFaceDownloadError#3"
    case .hfHtmlErrorResponse: return "FluidAudio.DownloadUtils.HuggingFaceDownloadError#4"
    case .unknownLoadFailure:
      return "EnviousWisprASR.ParakeetModelLoadSentryError.unknownLoadFailure"
    }
  }

  var sentrySemanticID: String {
    switch self {
    case .modelsModelNotFound: return "parakeet_load.models_model_not_found"
    case .modelsDownloadFailed: return "parakeet_load.models_download_failed"
    case .modelsLoadingFailed: return "parakeet_load.models_loading_failed"
    case .modelsCompilationFailed: return "parakeet_load.models_compilation_failed"
    case .offlineNetworkDisabled: return "parakeet_load.offline_network_disabled"
    case .offlineModelMissing: return "parakeet_load.offline_model_missing"
    case .hfInvalidResponse: return "parakeet_load.hf_invalid_response"
    case .hfRateLimited: return "parakeet_load.hf_rate_limited"
    case .hfDownloadFailed: return "parakeet_load.hf_download_failed"
    case .hfModelNotFound: return "parakeet_load.hf_model_not_found"
    case .hfHtmlErrorResponse: return "parakeet_load.hf_html_error_response"
    case .unknownLoadFailure: return "parakeet_load.unknown_load_failure"
    }
  }
}
