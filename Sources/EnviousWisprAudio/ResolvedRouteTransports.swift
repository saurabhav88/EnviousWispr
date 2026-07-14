import CoreAudio

/// A pure, per-recording OBSERVATION of the resolver's route decision, derived
/// into the low-cardinality transport facts the telemetry layer emits (#1376,
/// Bluetooth-capture epic Phase 1). Never a control input — nothing branches
/// capture on it; both sinks (`dictation.completed` PostHog + `SentryAudioExtras`)
/// read this one value instead of re-deriving from raw inputs
/// (`telemetry-observes-resolved-value-deny-by-default`).
///
/// `routeResolutionSource` is `"app_derived"` unless the caller supplies the
/// actual transport reported by the bound capture source.
public struct ResolvedRouteTransports: Sendable, Equatable {
  /// Transport of the user's picked device, or `"unknown"` on Auto / unmappable.
  public let selected: String
  /// Transport the decision binds (built-in for the capture-session path today).
  public let effective: String
  /// `CaptureRouteReason.rawValue` — the machine-readable route reason.
  public let routeReason: String
  /// Reserved for a backend-level fallback rung. With a single capture backend
  /// there is no backend to fall back to, so this is always absent today; the
  /// key stays so telemetry consumers keep a stable shape.
  public let routeFallbackReason: String?
  /// `explicit` when the user pinned a device, `auto` when on system-default,
  /// `unknown` reserved. Separates explicit user picks from Auto's system-default
  /// policy.
  public let inputSelectionMode: String
  /// Transport of the current default OUTPUT device (`"unknown"` if unreadable).
  /// The forced-built-in workaround only triggers under Bluetooth output.
  public let outputTransport: String
  /// How the value was obtained: `"app_derived"` or `"helper_reported"`.
  public let routeResolutionSource: String

  public init(
    selected: String,
    effective: String,
    routeReason: String,
    routeFallbackReason: String?,
    inputSelectionMode: String,
    outputTransport: String,
    routeResolutionSource: String
  ) {
    self.selected = selected
    self.effective = effective
    self.routeReason = routeReason
    self.routeFallbackReason = routeFallbackReason
    self.inputSelectionMode = inputSelectionMode
    self.outputTransport = outputTransport
    self.routeResolutionSource = routeResolutionSource
  }

  /// Derive the observed transports from a resolver decision plus the user's
  /// device selection. Total over the `CaptureSourceType × CaptureRouteReason`
  /// grid. The transport lookups reflect live CoreAudio device state, which the
  /// resolver decision was itself computed against a moment earlier.
  public static func derive(
    decision: CaptureRouteDecision,
    preferredInputDeviceIDOverride: String,
    actualBoundTransport: String? = nil,
    defaultInputDeviceID: () -> AudioDeviceID? = AudioDeviceEnumerator.defaultInputDeviceID,
    defaultOutputDeviceID: () -> AudioDeviceID? = AudioDeviceEnumerator.defaultOutputDeviceID,
    transportLabelForDevice: (AudioDeviceID) -> String? = AudioDeviceEnumerator.transportLabel(
      for:),
    transportLabelForUID: (String) -> String? = AudioDeviceEnumerator.transportLabel(forUID:)
  ) -> ResolvedRouteTransports {
    // The user's EXPLICIT pick is the settings mic picker, which binds to
    // `preferredInputDeviceIDOverride` ("Auto" = empty) — AND the route resolver
    // builds its decision from ONLY that value. So `selected` + selection mode
    // derive from `preferredInputDeviceIDOverride` alone, keeping them
    // consistent with `route_reason` (a bare `selectedInputDeviceUID` under an
    // empty picker is Auto to the resolver, not an explicit pick — #1387 cloud
    // review P2).
    let selectionMode = preferredInputDeviceIDOverride.isEmpty ? "auto" : "explicit"

    let selected =
      preferredInputDeviceIDOverride.isEmpty
      ? "unknown"
      : (transportLabelForUID(preferredInputDeviceIDOverride) ?? "unknown")

    let effective: String
    let usedActualBoundTransport: Bool
    switch decision.sourceType {
    case .halDeviceInput:
      if let actualBoundTransport {
        effective = actualBoundTransport
        usedActualBoundTransport = true
      } else {
        // Mirror HAL's own device resolution exactly: it binds the explicit
        // override when set, otherwise follows the live system-default input.
        // It NEVER consults `selectedInputDeviceUID` (that is only remembered
        // settings state), so `effective` must not either — deriving Auto from a
        // remembered device the mic never opens corrupts route telemetry (cloud
        // review P2, PR #1536).
        if !preferredInputDeviceIDOverride.isEmpty,
          let label = transportLabelForUID(preferredInputDeviceIDOverride)
        {
          effective = label
        } else if let defaultID = defaultInputDeviceID() {
          effective = transportLabelForDevice(defaultID) ?? "unknown"
        } else {
          effective = "unknown"
        }
        usedActualBoundTransport = false
      }
    }

    // No surviving route reason is a backend-level fallback rung (there is one
    // capture backend), so the fallback reason is always absent.
    let fallbackReason: String? = nil

    let outputTransport =
      defaultOutputDeviceID()
      .flatMap { transportLabelForDevice($0) } ?? "unknown"

    return ResolvedRouteTransports(
      selected: selected,
      effective: effective,
      routeReason: decision.reason.rawValue,
      routeFallbackReason: fallbackReason,
      inputSelectionMode: selectionMode,
      outputTransport: outputTransport,
      routeResolutionSource: usedActualBoundTransport ? "helper_reported" : "app_derived"
    )
  }
}
