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
    inputDeviceUIDSystemDefault: String?
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
  public let timestampNs: UInt64
  /// #455: when the interrupt/invalidate fired while a capture session was
  /// active, this is `timestampNs - capture-start-uptime-ns`. Nil for idle
  /// interrupts. Surfaces in the Sentry breadcrumb as
  /// `audio.recording_duration_ms` so triage can distinguish "fired
  /// immediately after start" (likely device binding race) from "fired
  /// mid-dictation" (likely launchd kill under memory pressure or system
  /// event).
  public let recordingDurationNs: UInt64?

  public init(
    kind: XPCErrorKind,
    sessionID: UInt64?,
    timestampNs: UInt64,
    recordingDurationNs: UInt64? = nil
  ) {
    self.kind = kind
    self.sessionID = sessionID
    self.timestampNs = timestampNs
    self.recordingDurationNs = recordingDurationNs
  }
}
