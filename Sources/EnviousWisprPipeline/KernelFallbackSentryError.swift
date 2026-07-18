import EnviousWisprCore
import Foundation

/// Exhaustive replacement for the raw `NSError(domain: "EnviousWispr", code:
/// ...)` fallback literals in `KernelLifecycleTelemetrySink` and
/// `KernelDictationDriver` (#1525 PR I-A). Each case pins the exact string
/// already sent in production — measured, not derived — so adding, removing,
/// or reordering a case here can never re-point a shipped Sentry issue onto
/// another's. `.xpcServiceError` is constructed at TWO call sites (the
/// lifecycle sink's `.asrInterrupted` handler and the driver's direct-emit
/// fallback when routing doesn't reach the sink) — both use this ONE case.
enum KernelFallbackSentryError: Error, LocalizedError, Sendable {
  case xpcServiceError(backendLabel: String)
  case modelLoadFailed
  case captureStartFailed
  case noMicrophoneFound
  case transcriptionFailed
  case permissionDenied
  case prepareFailed

  var errorDescription: String? {
    switch self {
    case .xpcServiceError(let backendLabel):
      return "ASR XPC service crashed (\(backendLabel))"
    case .modelLoadFailed:
      return "Model load failed"
    case .captureStartFailed:
      return "Recording failed"
    case .noMicrophoneFound:
      return "No usable microphone device was found"
    case .transcriptionFailed:
      return "Transcription failed"
    case .permissionDenied:
      return "Microphone permission denied"
    case .prepareFailed:
      return "Prepare failed"
    }
  }
}

// MARK: - Sentry identity

/// Pins each case's Sentry grouping key to the exact string it has been
/// sending in production (#1525 PR I-A), mirroring `HeartPathError`'s shipped
/// pattern (#1524). The switch is exhaustive, so a new case cannot compile
/// until it declares an identity.
extension KernelFallbackSentryError: StableSentryErrorIdentity {
  var sentryFingerprintDescriptor: String {
    switch self {
    case .xpcServiceError: return "EnviousWispr#-3"
    case .modelLoadFailed: return "EnviousWispr#-10"
    case .captureStartFailed: return "EnviousWispr#-11"
    case .noMicrophoneFound: return "EnviousWispr#-16"
    case .transcriptionFailed: return "EnviousWispr#-13"
    case .permissionDenied: return "EnviousWispr#-14"
    case .prepareFailed: return "EnviousWispr#-15"
    }
  }

  var sentrySemanticID: String {
    switch self {
    case .xpcServiceError: return "kernel.xpc_service_error"
    case .modelLoadFailed: return "kernel.model_load_failed"
    case .captureStartFailed: return "kernel.capture_start_failed"
    case .noMicrophoneFound: return "kernel.no_microphone_found"
    case .transcriptionFailed: return "kernel.transcription_failed"
    case .permissionDenied: return "kernel.permission_denied"
    case .prepareFailed: return "kernel.prepare_failed"
    }
  }
}
