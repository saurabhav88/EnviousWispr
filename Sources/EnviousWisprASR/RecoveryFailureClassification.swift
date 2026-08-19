import EnviousWisprCore
import EnviousWisprServices

/// #2132 — classify an ASR failure caught by the crash-recovery replay.
///
/// **Why this lives in `EnviousWisprASR` and not beside its caller.**
/// `RecoverySpoolReplayer` (AppKit) held the only classifier, and four of the
/// error families it needed are `internal` to THIS module and deliberately kept
/// that way (D-028). So the old classifier could not see them and every one of
/// them landed in `.other`: 18 production failures in the 30 days to 2026-08-19,
/// 100% unclassified. `classify`'s own doc comment named the cause — "`ASRError`
/// is ASR-module-internal, kept isolated per D-028" — and reserved `.notReady`
/// for the in-process producer this function finally supplies.
///
/// Exports a CLASSIFICATION, never the types, so the isolation D-028 protects is
/// untouched.
///
/// `nil` means "not a family this module owns" — a foreign vendor or framework
/// error, which `ParakeetBackend.transcribe` deliberately rethrows unchanged
/// (#1525 PR I-B, live case `com.apple.CoreML#0`). The caller maps `nil` to
/// `.other` and keeps the error's own Sentry identity through the boundary
/// normalizer for its seam. No switch over `any Error` can be exhaustive, so the
/// optional is the honest return type rather than a total-looking lie.
package func recoveryFailureClass(for error: any Error) -> RecoveryFailureClass? {
  // ORDER IS LOAD-BEARING: the unreachable-service case must be tested before
  // the general transport case or the shipped `xpc_unreachable` series silently
  // stops being produced. Pinned by `serviceUnreachableOutranksGeneralTransport`.
  if let transport = error as? XPCASRTransportError {
    return transport.isServiceUnreachable ? .xpcUnreachable : .xpcTransport
  }
  // Three cancellation vehicles, one actionable class. `KernelDictationDriver`
  // already groups the latter two exactly this way.
  if error is ASRLoadSupersededError || error is ASRLoadCancelledError
    || error is CancellationError
  {
    return .cancelled
  }
  if let asrError = error as? ASRError {
    switch asrError {
    case .notReady: return .notReady
    case .transcriptionFailed: return .transcriptionFailed
    // Unreachable on a batch replay; classifying them would assert a
    // reachability this path does not have.
    case .streamingNotSupported, .streamingTimeout: return nil
    }
  }
  if error is WhisperKitModelLoadSentryError { return .whisperKitModelLoad }
  if error is ParakeetModelLoadSentryError { return .parakeetModelLoad }
  if error is ParakeetTranscriptionSentryError { return .parakeetTranscription }
  if error is ASRManagerNotOwnedError { return .managerNotOwned }
  return nil
}
