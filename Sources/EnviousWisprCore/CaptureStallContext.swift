import Foundation

/// Context attached to a stalled-capture telemetry event. Built by an audio
/// source (`AVAudioEngineSource`, `AVCaptureSessionSource`, or `AudioCaptureProxy`)
/// at watchdog-fire time and consumed by the pipeline's emission site.
///
/// All fields are Sendable and safe to carry across actor boundaries. No PII:
/// device UIDs are opaque CoreAudio identifiers, not human-visible strings.
public struct CaptureStallContext: Sendable {
  public let sessionID: UInt64
  public let armedAtUptimeNs: UInt64
  public let firedAtUptimeNs: UInt64
  public let route: String
  public let sourceType: String
  public let engineStartedSuccessfully: Bool
  public let tapInstalled: Bool
  public let formatMismatchObserved: Bool
  public let inputDeviceUIDPreferred: String?
  public let inputDeviceUIDSystemDefault: String?
  // #1376: resolved-route transports, populated where the resolver decision is
  // available (the XPC proxy stall path). The direct-source stall paths leave
  // these nil. Low-cardinality transport/reason strings; no PII.
  public let selectedTransport: String?
  public let effectiveTransport: String?
  public let routeReason: String?
  public let routeFallbackReason: String?
  public let inputSelectionMode: String?
  public let outputTransport: String?
  public let routeResolutionSource: String?
  // #1434: capture-health fields. The stall event fires BEFORE stopCapture()
  // returns, so it can never read the stop-time `CaptureStopMetadata` — the
  // SOURCE stamps rate/divergence from its own live state at watchdog-fire
  // time (direct HAL stalls populate them; the XPC proxy's host-side watchdog
  // cannot read helper state pre-stop and leaves them nil). Stabilization
  // flags are kernel-side observations merged in the kernel's stall handler
  // via `enrichedWithStabilizationFlags` before emission.
  public let nativeRateHz: Double?
  public let rateDivergenceDetected: Bool?
  public let formatStabilized: Bool?
  public let captureRebuiltForFormat: Bool?

  public init(
    sessionID: UInt64,
    armedAtUptimeNs: UInt64,
    firedAtUptimeNs: UInt64,
    route: String,
    sourceType: String,
    engineStartedSuccessfully: Bool,
    tapInstalled: Bool,
    formatMismatchObserved: Bool,
    inputDeviceUIDPreferred: String?,
    inputDeviceUIDSystemDefault: String?,
    selectedTransport: String? = nil,
    effectiveTransport: String? = nil,
    routeReason: String? = nil,
    routeFallbackReason: String? = nil,
    inputSelectionMode: String? = nil,
    outputTransport: String? = nil,
    routeResolutionSource: String? = nil,
    nativeRateHz: Double? = nil,
    rateDivergenceDetected: Bool? = nil,
    formatStabilized: Bool? = nil,
    captureRebuiltForFormat: Bool? = nil
  ) {
    self.sessionID = sessionID
    self.armedAtUptimeNs = armedAtUptimeNs
    self.firedAtUptimeNs = firedAtUptimeNs
    self.route = route
    self.sourceType = sourceType
    self.engineStartedSuccessfully = engineStartedSuccessfully
    self.tapInstalled = tapInstalled
    self.formatMismatchObserved = formatMismatchObserved
    self.inputDeviceUIDPreferred = inputDeviceUIDPreferred
    self.inputDeviceUIDSystemDefault = inputDeviceUIDSystemDefault
    self.selectedTransport = selectedTransport
    self.effectiveTransport = effectiveTransport
    self.routeReason = routeReason
    self.routeFallbackReason = routeFallbackReason
    self.inputSelectionMode = inputSelectionMode
    self.outputTransport = outputTransport
    self.routeResolutionSource = routeResolutionSource
    self.nativeRateHz = nativeRateHz
    self.rateDivergenceDetected = rateDivergenceDetected
    self.formatStabilized = formatStabilized
    self.captureRebuiltForFormat = captureRebuiltForFormat
  }

  /// Kernel-side enrichment (#1434): the kernel owns the stabilization record
  /// (private telemetry state) and merges it into the context inside its own
  /// stall handler; the observer stays a plain forwarder. Source-stamped
  /// fields are preserved as-is.
  public func enrichedWithStabilizationFlags(
    formatStabilized: Bool?, captureRebuiltForFormat: Bool?
  ) -> CaptureStallContext {
    CaptureStallContext(
      sessionID: sessionID,
      armedAtUptimeNs: armedAtUptimeNs,
      firedAtUptimeNs: firedAtUptimeNs,
      route: route,
      sourceType: sourceType,
      engineStartedSuccessfully: engineStartedSuccessfully,
      tapInstalled: tapInstalled,
      formatMismatchObserved: formatMismatchObserved,
      inputDeviceUIDPreferred: inputDeviceUIDPreferred,
      inputDeviceUIDSystemDefault: inputDeviceUIDSystemDefault,
      selectedTransport: selectedTransport,
      effectiveTransport: effectiveTransport,
      routeReason: routeReason,
      routeFallbackReason: routeFallbackReason,
      inputSelectionMode: inputSelectionMode,
      outputTransport: outputTransport,
      routeResolutionSource: routeResolutionSource,
      nativeRateHz: nativeRateHz,
      rateDivergenceDetected: rateDivergenceDetected,
      formatStabilized: formatStabilized,
      captureRebuiltForFormat: captureRebuiltForFormat
    )
  }
}

/// Context for `AVCaptureSessionSource` interruption / runtime-error notifications.
/// Carries the diagnostic payload (reason code, runtime NSError fields) that the
/// underlying notification userInfo would otherwise drop on the floor.
public struct CaptureSessionInterruptionContext: Sendable {
  public enum Kind: String, Sendable {
    case wasInterrupted
    case runtimeError
  }

  public let kind: Kind
  public let reasonCode: Int?
  public let reasonLabel: String?
  public let errorDomain: String?
  public let errorCode: Int?
  public let errorDescription: String?
  public let sessionID: UInt64
  public let isActivelyCapturing: Bool

  public init(
    kind: Kind,
    reasonCode: Int?,
    reasonLabel: String?,
    errorDomain: String?,
    errorCode: Int?,
    errorDescription: String?,
    sessionID: UInt64,
    isActivelyCapturing: Bool
  ) {
    self.kind = kind
    self.reasonCode = reasonCode
    self.reasonLabel = reasonLabel
    self.errorDomain = errorDomain
    self.errorCode = errorCode
    self.errorDescription = errorDescription
    self.sessionID = sessionID
    self.isActivelyCapturing = isActivelyCapturing
  }
}

/// Context for a swallowed XPC reply-path error on a non-throwing proxy call
/// (stopCapture / getSamplesSnapshot / getSpeechSegments). Reported via
/// `onXPCReplyFailed` before the proxy returns its empty default, so the
/// pipeline can emit the correct root cause instead of misrouting into
/// "no_audio_captured".
public struct XPCReplyFailureContext: Sendable {
  public let replyStage: String
  public let errorDomain: String
  public let errorCode: Int
  public let errorDescription: String
  public let sessionID: UInt64

  public init(
    replyStage: String,
    errorDomain: String,
    errorCode: Int,
    errorDescription: String,
    sessionID: UInt64
  ) {
    self.replyStage = replyStage
    self.errorDomain = errorDomain
    self.errorCode = errorCode
    self.errorDescription = errorDescription
    self.sessionID = sessionID
  }
}

/// Context for one resolved start-op retry inside `AudioCaptureProxy` (#1194).
/// Reported via `onAudioStartRetryResolved` after the bounded
/// reacquire-and-resend resolves either way. Diagnostic-only: consumers must
/// not branch control flow on it. No PII — four low-cardinality fields.
public struct AudioStartRetryContext: Sendable {
  /// The failed public stage: `start_engine` | `begin_capture` | `start_engine_prewarm`.
  public let stage: String
  /// What killed the first attempt: `wedged` | `service_unreachable`.
  public let trigger: String
  /// `recovered` (silent same-press save) | `exhausted` (today's failure UX).
  public let outcome: String
  /// Line-death detection → retry resolution latency in milliseconds.
  public let recoveryMs: Int

  public init(stage: String, trigger: String, outcome: String, recoveryMs: Int) {
    self.stage = stage
    self.trigger = trigger
    self.outcome = outcome
    self.recoveryMs = recoveryMs
  }
}

/// Classifies XPC interruption / invalidation events for the `onXPCServiceError`
/// callback on `AudioCaptureInterface`. Exhaustive: any new XPC channel
/// requires adding a case, which the compiler enforces at every consumer
/// switch site.
public enum XPCErrorKind: String, Sendable {
  case interruptCapturing
  case invalidateCapturing
  case invalidateIdle
}

/// Context for XPC interrupt / invalidate handler fires. Consumed by
/// the former root state which emits the captureError.
public struct XPCErrorContext: Sendable {
  public let kind: XPCErrorKind
  public let sessionID: UInt64?
  /// #455: when the interrupt/invalidate fired while a capture session was
  /// active, this is the elapsed nanoseconds since capture start. Nil for idle
  /// interrupts. Surfaces in the Sentry breadcrumb as
  /// `audio.recording_duration_ms` so triage can distinguish "fired
  /// immediately after start" (likely device binding race) from "fired
  /// mid-dictation" (likely launchd kill under memory pressure or system
  /// event).
  public let recordingDurationNs: UInt64?

  public init(
    kind: XPCErrorKind,
    sessionID: UInt64?,
    recordingDurationNs: UInt64? = nil
  ) {
    self.kind = kind
    self.sessionID = sessionID
    self.recordingDurationNs = recordingDurationNs
  }
}
