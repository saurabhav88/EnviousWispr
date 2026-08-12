import EnviousWisprCore
import EnviousWisprFluidAudioBridge
import Foundation

/// #1525 PR I-B: pinned Sentry identity for FluidAudio's raw `ASRError` (transcription
/// path), built from `FluidAudioASRErrorKind` — never from `FluidAudio.ASRError` directly
/// (see `EnviousWisprFluidAudioBridge`'s naming-trap doc comment). `CustomNSError`
/// conforms so the app-owned domain/code automatically applies the moment anything
/// downstream does `error as NSError` (exactly what `XPCErrorSanitizer.sanitizeForXPC`
/// already does) — no manual bridging call needed.
enum ParakeetTranscriptionSentryError: Error, LocalizedError, CustomNSError, Sendable, Equatable {
  case notInitialized(String)
  case invalidAudioData(String)
  case modelLoadFailed(String)
  case processingFailed(String)
  case modelCompilationFailed(String)
  case unsupportedPlatform(String)
  case streamingConversionFailed(String)
  case fileAccessFailed(String)
  /// #1654: vendor case added by the 2026-08-08 pin bump (#1985). Appended, never
  /// inserted — every identity below is pinned by position for Sentry grouping.
  case encoderInstantiationFailed(String)
  case unknownTranscriptionFailure(String)

  static let errorDomain = "EnviousWisprASR.ParakeetTranscriptionSentryError"

  var errorCode: Int {
    switch self {
    case .notInitialized: return 0
    case .invalidAudioData: return 1
    case .modelLoadFailed: return 2
    case .processingFailed: return 3
    case .modelCompilationFailed: return 4
    case .unsupportedPlatform: return 5
    case .streamingConversionFailed: return 6
    case .fileAccessFailed: return 7
    case .unknownTranscriptionFailure: return 8
    // Appended as 9, not inserted at 8: renumbering would silently re-point every
    // existing Sentry group at a different cause.
    case .encoderInstantiationFailed: return 9
    }
  }

  var errorDescription: String? {
    switch self {
    case .notInitialized(let d), .invalidAudioData(let d), .modelLoadFailed(let d),
      .processingFailed(let d), .modelCompilationFailed(let d), .unsupportedPlatform(let d),
      .streamingConversionFailed(let d), .fileAccessFailed(let d),
      .encoderInstantiationFailed(let d), .unknownTranscriptionFailure(let d):
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

  init(mapping kind: FluidAudioASRErrorKind) {
    switch kind {
    case .notInitialized(let d): self = .notInitialized(d)
    case .invalidAudioData(let d): self = .invalidAudioData(d)
    case .modelLoadFailed(let d): self = .modelLoadFailed(d)
    case .processingFailed(let d): self = .processingFailed(d)
    case .modelCompilationFailed(let d): self = .modelCompilationFailed(d)
    case .unsupportedPlatform(let d): self = .unsupportedPlatform(d)
    case .streamingConversionFailed(let d): self = .streamingConversionFailed(d)
    case .fileAccessFailed(let d): self = .fileAccessFailed(d)
    case .encoderInstantiationFailed(let d): self = .encoderInstantiationFailed(d)
    case .unknownFutureCase(let d): self = .unknownTranscriptionFailure(d)
    }
  }

  /// Reconstructs the typed, conforming error from an NSError that survived the XPC
  /// round-trip (domain/code preserved by `XPCErrorSanitizer.sanitizeForXPC`). Returns
  /// `nil` if the domain doesn't match — a genuinely unrelated XPC-layer error.
  init?(reconstructingFrom error: NSError) {
    guard error.domain == Self.errorDomain else { return nil }
    let d = error.localizedDescription
    switch error.code {
    case 0: self = .notInitialized(d)
    case 1: self = .invalidAudioData(d)
    case 2: self = .modelLoadFailed(d)
    case 3: self = .processingFailed(d)
    case 4: self = .modelCompilationFailed(d)
    case 5: self = .unsupportedPlatform(d)
    case 6: self = .streamingConversionFailed(d)
    case 7: self = .fileAccessFailed(d)
    case 8: self = .unknownTranscriptionFailure(d)
    case 9: self = .encoderInstantiationFailed(d)
    default: return nil
    }
  }
}

extension ParakeetTranscriptionSentryError: StableSentryErrorIdentity {
  var sentryFingerprintDescriptor: String {
    // No live Sentry history found for a "FluidAudio.ASRError"-identified descriptor
    // in a 90-day search — every case below is a defensive pin.
    switch self {
    case .notInitialized: return "FluidAudio.ASRError#0"
    case .invalidAudioData: return "FluidAudio.ASRError#1"
    case .modelLoadFailed: return "FluidAudio.ASRError#2"
    case .processingFailed: return "FluidAudio.ASRError#3"
    case .modelCompilationFailed: return "FluidAudio.ASRError#4"
    case .unsupportedPlatform: return "FluidAudio.ASRError#5"
    case .streamingConversionFailed: return "FluidAudio.ASRError#6"
    case .fileAccessFailed: return "FluidAudio.ASRError#7"
    // Vendor declaration ordinal 8 at pin `a1767d86`; `#8` was previously unused.
    case .encoderInstantiationFailed: return "FluidAudio.ASRError#8"
    case .unknownTranscriptionFailure:
      return "EnviousWisprASR.ParakeetTranscriptionSentryError.unknownTranscriptionFailure"
    }
  }

  var sentrySemanticID: String {
    switch self {
    case .notInitialized: return "parakeet_transcribe.not_initialized"
    case .invalidAudioData: return "parakeet_transcribe.invalid_audio_data"
    case .modelLoadFailed: return "parakeet_transcribe.model_load_failed"
    case .processingFailed: return "parakeet_transcribe.processing_failed"
    case .modelCompilationFailed: return "parakeet_transcribe.model_compilation_failed"
    case .unsupportedPlatform: return "parakeet_transcribe.unsupported_platform"
    case .streamingConversionFailed: return "parakeet_transcribe.streaming_conversion_failed"
    case .fileAccessFailed: return "parakeet_transcribe.file_access_failed"
    case .encoderInstantiationFailed:
      return "parakeet_transcribe.encoder_instantiation_failed"
    case .unknownTranscriptionFailure: return "parakeet_transcribe.unknown_transcription_failure"
    }
  }
}
