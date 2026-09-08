import Foundation

/// #1908: relocated from the now-deleted `XPCOperationSignalFile.swift`
/// (`withASRXPCOperationSignal`'s XPC wedge-signal mechanism it belonged to
/// has no producer left — the last XPC helper collapsed in-process). This
/// type itself already had no live producer BEFORE this change (see the pin
/// comment below); it survives the deletion for the same reason it already
/// survived one prior producer's retirement: preserving a shipped Sentry
/// identity string that real historical production issues reference.
public struct XPCOperationSignalWedgeError: LocalizedError, Sendable {
  public let service: String
  public let stage: String
  public let observedPhase: String

  public init(service: String, stage: String, observedPhase: String) {
    self.service = service
    self.stage = stage
    self.observedPhase = observedPhase
  }

  public var errorDescription: String? {
    "\(service) XPC operation wedged during \(stage) after signal phase \(observedPhase)"
  }
}

/// #1525 PR G. Pins this struct's exact measured current wire identity
/// (`docs/audits/2026-07-14-1525-pr-g-preflight.md` §1). A plain
/// non-switching property matches this one-shape struct and the shipped
/// `ModelLoadWatchdog.WedgeError` pattern. Its stored diagnostic fields
/// (`service`/`stage`/`observedPhase`) do not enter the descriptor. This
/// descriptor has 2 live production issues riding on it (ENVIOUSWISPR-22,
/// ENVIOUSWISPR-1B, 3 users total) from a producer
/// (`AudioCaptureProxy.swift`) deleted the same day this PR was drafted
/// (`f1b2a331`, #1546) — the ASR-side throw site (`ASRManagerProxy.swift:660`,
/// itself deleted by #1908) reached only a breadcrumb, not a Sentry issue,
/// so this pin has preserved dormant history since before this change and
/// keeps doing so now that no throw site remains at all. NEVER change this
/// string once shipped.
extension XPCOperationSignalWedgeError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String {
    "EnviousWisprCore.XPCOperationSignalWedgeError#1"
  }

  public var sentrySemanticID: String { "xpc.operation_signal_wedge" }
}
