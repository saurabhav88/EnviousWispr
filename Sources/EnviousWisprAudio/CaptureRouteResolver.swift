import CoreAudio

/// Which capture backend to use. The HAL device source is the sole backend.
public enum CaptureSourceType: Sendable {
  /// HAL-backed input source; follows the live system-default input when no
  /// target UID is supplied.
  case halDeviceInput
}

/// Machine-readable reason for the route decision. Used for telemetry.
public enum CaptureRouteReason: String, Sendable {
  case btOutputAutoInput
  case btOutputUserSelectedDevice
  case noBTAutoInput
  case noBTUserSelectedDevice
}

extension CaptureRouteReason {
  /// The single authority mapping a route reason to the low-cardinality
  /// `currentAudioRoute` label used by Sentry audio extras (#1376). Both the
  /// in-process `AudioCaptureManager` and the app-side `AudioCaptureProxy`
  /// derive their `currentAudioRoute` from this, so the coarse label is not
  /// re-implemented per conformer.
  public var coarseAudioRouteLabel: String {
    switch self {
    case .noBTAutoInput, .noBTUserSelectedDevice:
      return "built_in_mic"
    case .btOutputAutoInput, .btOutputUserSelectedDevice:
      return "hal_device_input"
    }
  }
}

extension CaptureRouteDecision {
  /// The changed-only predicate for the `onRouteResolved` producer (#1376):
  /// fires on the first resolution (`prior == nil`) and thereafter only when
  /// `reason` or `sourceType` differs from the prior decision. The single
  /// authority both `AudioCaptureManager` and `AudioCaptureProxy` use so the
  /// changed-only semantics are defined once.
  public static func routeResolvedChanged(
    from prior: CaptureRouteDecision?, to next: CaptureRouteDecision
  ) -> Bool {
    guard let prior else { return true }
    return prior.reason != next.reason || prior.sourceType != next.sourceType
  }
}

/// The result of route resolution — tells AudioCaptureManager which source to create and why.
public struct CaptureRouteDecision: Sendable {
  public let sourceType: CaptureSourceType
  public let reason: CaptureRouteReason
  public let rationale: String
  /// Concrete device UID for HALDeviceInputSource. Nil means follow the live
  /// system-default input device at prepare time.
  public let effectiveDeviceUID: String?

  public init(
    sourceType: CaptureSourceType,
    reason: CaptureRouteReason,
    rationale: String,
    effectiveDeviceUID: String? = nil
  ) {
    self.sourceType = sourceType
    self.reason = reason
    self.rationale = rationale
    self.effectiveDeviceUID = effectiveDeviceUID
  }
}

/// Decides which `AudioInputSource` to use based on output route, user input preference, and policy.
///
/// Ownership: source selection, device discovery, transport filtering, user preference interpretation.
/// Does NOT create sources — returns a decision that AudioCaptureManager acts on.
@MainActor
struct CaptureRouteResolver {

  var defaultOutputDeviceID: () -> AudioDeviceID? = AudioDeviceEnumerator.defaultOutputDeviceID
  var isBluetoothOutputDevice: (AudioDeviceID) -> Bool = AudioDeviceEnumerator.isBluetoothDevice

  /// Resolve which capture source to use. Every route now returns the HAL
  /// device source; the reason distinguishes BT-output vs no-BT context and
  /// auto vs explicit device pick for telemetry only.
  ///
  /// - Parameter preferredInputDeviceUID: User's explicit device choice. Empty = Auto.
  func resolve(preferredInputDeviceUID: String) -> CaptureRouteDecision {
    let btOutputActive: Bool
    if let outID = defaultOutputDeviceID() {
      btOutputActive = isBluetoothOutputDevice(outID)
    } else {
      btOutputActive = false
    }

    // The HAL device source opens the chosen input directly (nil UID follows
    // the live system default), so it serves every output route.
    let effectiveDeviceUID = preferredInputDeviceUID.isEmpty ? nil : preferredInputDeviceUID
    let reason: CaptureRouteReason
    let rationale: String
    switch (btOutputActive, preferredInputDeviceUID.isEmpty) {
    case (true, true):
      reason = .btOutputAutoInput
      rationale = "BT output active, auto input: HAL device source follows system default"
    case (true, false):
      reason = .btOutputUserSelectedDevice
      rationale =
        "BT output active, explicit device pick: HAL device source targets \(preferredInputDeviceUID)"
    case (false, true):
      reason = .noBTAutoInput
      rationale = "No BT output: HAL device source follows system default"
    case (false, false):
      reason = .noBTUserSelectedDevice
      rationale = "No BT output: HAL device source targets \(preferredInputDeviceUID)"
    }

    return CaptureRouteDecision(
      sourceType: .halDeviceInput,
      reason: reason,
      rationale: rationale,
      effectiveDeviceUID: effectiveDeviceUID
    )
  }
}
