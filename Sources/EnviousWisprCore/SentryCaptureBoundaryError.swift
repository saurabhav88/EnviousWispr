import Foundation

/// Closed, exhaustive boundary-violation identity for #1525 PR J-1's compile-time guard.
/// Every case is a FIXED literal — the two associated-`Int` cases carry an OS/vendor's
/// own stable numeric code for the one proven external family each represents, never our
/// own ordinal. A future error type must still be given a real `StableSentryErrorIdentity`
/// conformance to reach `captureError` through its normal path; this type exists only for
/// the small number of seams named below, each of which normalizes explicitly at ONE
/// reviewed call site. Reusing an existing `.unexpected*` case for a genuinely new class of
/// error is possible (this enum cannot prevent that by itself) but requires the author to
/// explicitly choose to misuse a "should never happen" case rather than give their new type
/// a real conformance — a visible, reviewable choice, not a silent one.
package enum SentryCaptureBoundaryError: Error, StableSentryErrorIdentity, Sendable, Equatable {
  /// Row 5: raw `URLError` reaching `TextProcessingRunner`'s polish-alerting seam.
  case urlTransport(code: Int)
  /// Row 8: Parakeet's raw-vendor transcription passthrough when the domain is CoreML.
  case coreML(code: Int)
  case unexpectedGenerationFailure  // rows 5 (non-URLError branch) and 9 (AFM)
  case unexpectedTranscriptionFailure  // row 8 (non-CoreML)
  case unexpectedLegacyKeyCleanupFailure  // row 10
  case unexpectedHeartControlFailure  // row 11

  package var sentryFingerprintDescriptor: String {
    switch self {
    case .urlTransport(let code): return "NSURLErrorDomain#\(code)"
    case .coreML(let code): return "com.apple.CoreML#\(code)"
    case .unexpectedGenerationFailure:
      return "EnviousWisprCore.SentryCaptureBoundaryError.unexpected_generation_failure"
    case .unexpectedTranscriptionFailure:
      return "EnviousWisprCore.SentryCaptureBoundaryError.unexpected_transcription_failure"
    case .unexpectedLegacyKeyCleanupFailure:
      return "EnviousWisprCore.SentryCaptureBoundaryError.unexpected_legacy_key_cleanup_failure"
    case .unexpectedHeartControlFailure:
      return "EnviousWisprCore.SentryCaptureBoundaryError.unexpected_heart_control_failure"
    }
  }

  package var sentrySemanticID: String {
    switch self {
    case .urlTransport: return "polish.external_url_transport"
    case .coreML: return "asr.external_coreml"
    case .unexpectedGenerationFailure: return "boundary.unexpected_generation_failure"
    case .unexpectedTranscriptionFailure: return "boundary.unexpected_transcription_failure"
    case .unexpectedLegacyKeyCleanupFailure: return "boundary.unexpected_legacy_key_cleanup_failure"
    case .unexpectedHeartControlFailure: return "boundary.unexpected_heart_control_failure"
    }
  }
}

// MARK: - Seam normalizers

/// One normalizer per seam that stays generic (`any Error`) and must produce a
/// conforming value before calling the narrowed `SentryBreadcrumb.captureError`.
/// Each keeps an already-conforming value unchanged; only a genuine miss falls to
/// this enum. Living beside the cases they construct keeps the boundary
/// vocabulary and its normalization logic a single authority (§3c) rather than
/// five ad-hoc cast-or-fallback copies at each call site.
extension SentryCaptureBoundaryError {
  /// Rows 5/9: cloud-polish transport errors and AFM generation failures. A raw
  /// `URLError` preserves its exact historical fingerprint; anything else
  /// non-conforming becomes the shared "unexpected generation failure" identity.
  package static func normalizingGenerationFailure(
    _ error: any Error
  ) -> any Error & StableSentryErrorIdentity {
    if let stable = error as? any Error & StableSentryErrorIdentity { return stable }
    if let urlError = error as? URLError {
      return SentryCaptureBoundaryError.urlTransport(code: urlError.code.rawValue)
    }
    return SentryCaptureBoundaryError.unexpectedGenerationFailure
  }

  /// Row 8: Parakeet's raw-vendor transcription passthrough. A raw CoreML
  /// `NSError` preserves its exact historical fingerprint; anything else
  /// non-conforming becomes the shared "unexpected transcription failure" identity.
  package static func normalizingTranscriptionFailure(
    _ error: any Error
  ) -> any Error & StableSentryErrorIdentity {
    if let stable = error as? any Error & StableSentryErrorIdentity { return stable }
    let ns = error as NSError
    if ns.domain == "com.apple.CoreML" {
      return SentryCaptureBoundaryError.coreML(code: ns.code)
    }
    return SentryCaptureBoundaryError.unexpectedTranscriptionFailure
  }

  /// Row 10: the legacy plaintext API-key cleanup failure seam.
  package static func normalizingLegacyKeyCleanupFailure(
    _ error: any Error
  ) -> any Error & StableSentryErrorIdentity {
    (error as? any Error & StableSentryErrorIdentity)
      ?? SentryCaptureBoundaryError.unexpectedLegacyKeyCleanupFailure
  }

  /// Row 11: `HeartControlRecovery`'s two dispatch-failure methods.
  package static func normalizingHeartControlFailure(
    _ error: any Error
  ) -> any Error & StableSentryErrorIdentity {
    (error as? any Error & StableSentryErrorIdentity)
      ?? SentryCaptureBoundaryError.unexpectedHeartControlFailure
  }

  /// Row 7 (#1658): the kernel's `modelLoadError` write site. A non-conforming
  /// model-load error — in practice the XPC last-resort raw `NSError`
  /// (`ASRManagerProxy`, reached when neither typed reconstructor recognizes the
  /// bridged domain/code) — keeps its own bridged identity instead of falling to
  /// the generic `KernelFallbackSentryError.modelLoadFailed` read-side fallback.
  package static func normalizingModelLoadFailure(
    _ error: any Error
  ) -> any Error & StableSentryErrorIdentity {
    if let stable = error as? any Error & StableSentryErrorIdentity {
      return stable
    }
    return UnrecognizedModelLoadSentryError(error)
  }
}

/// Preserves the legacy bridged identity for a model-load failure that reached the
/// kernel without its own `StableSentryErrorIdentity` (#1658). A struct, not a
/// `SentryCaptureBoundaryError` case: the descriptor carries the raw error's own
/// dynamic `domain#code`, which would break that enum's fixed-literal charter.
package struct UnrecognizedModelLoadSentryError:
  Error, StableSentryErrorIdentity, Sendable, Equatable
{
  package let sentryFingerprintDescriptor: String
  package let sentrySemanticID = "asr.unrecognized_model_load_failure"

  package init(_ error: any Error) {
    sentryFingerprintDescriptor = SentryErrorDescriptor.bridged(error)
  }
}
