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
  /// Present iff `routeReason` is a fallback rung (`fallbackToEngine` /
  /// `failedNoFallback`); absent otherwise. The presence IS the signal.
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
    selectedInputDeviceUID: String,
    actualBoundTransport: String? = nil
  ) -> ResolvedRouteTransports {
    // The user's EXPLICIT pick is the settings mic picker, which binds to
    // `preferredInputDeviceIDOverride` ("Auto" = empty) — AND the route resolver
    // builds its decision from ONLY that value. So `selected` + selection mode
    // derive from `preferredInputDeviceIDOverride` alone, keeping them
    // consistent with `route_reason` (a bare `selectedInputDeviceUID` under an
    // empty picker is Auto to the resolver, not an explicit pick — #1387 cloud
    // review P2). `selectedInputDeviceUID` still feeds `effective` below because
    // the engine opens it as a fallback.
    let selectionMode = preferredInputDeviceIDOverride.isEmpty ? "auto" : "explicit"

    let selected =
      preferredInputDeviceIDOverride.isEmpty
      ? "unknown"
      : (AudioDeviceEnumerator.transportLabel(forUID: preferredInputDeviceIDOverride) ?? "unknown")

    let effective: String
    let usedActualBoundTransport: Bool
    switch decision.sourceType {
    case .audioEngine:
      // Mirror AVAudioEngineSource's device resolution exactly: the preferred
      // override, else the stored selection, else the system-default input
      // (`AVAudioEngineSource.swift:227-243` — `resolvedDeviceID ??
      // defaultInputDeviceID()`). A pinned-but-disconnected UID therefore
      // reports the default input transport the engine actually opens.
      let engineUID =
        preferredInputDeviceIDOverride.isEmpty
        ? selectedInputDeviceUID : preferredInputDeviceIDOverride
      if !engineUID.isEmpty, let label = AudioDeviceEnumerator.transportLabel(forUID: engineUID) {
        effective = label
      } else if let defaultID = AudioDeviceEnumerator.defaultInputDeviceID() {
        effective = AudioDeviceEnumerator.transportLabel(for: defaultID) ?? "unknown"
      } else {
        effective = "unknown"
      }
      usedActualBoundTransport = false
    case .halDeviceInput:
      if let actualBoundTransport {
        effective = actualBoundTransport
        usedActualBoundTransport = true
      } else {
        let halUID =
          preferredInputDeviceIDOverride.isEmpty
          ? selectedInputDeviceUID : preferredInputDeviceIDOverride
        if !halUID.isEmpty, let label = AudioDeviceEnumerator.transportLabel(forUID: halUID) {
          effective = label
        } else if let defaultID = AudioDeviceEnumerator.defaultInputDeviceID() {
          effective = AudioDeviceEnumerator.transportLabel(for: defaultID) ?? "unknown"
        } else {
          effective = "unknown"
        }
        usedActualBoundTransport = false
      }
    }

    let fallbackReason: String? =
      (decision.reason == .fallbackToEngine || decision.reason == .failedNoFallback)
      ? decision.reason.rawValue : nil

    let outputTransport =
      AudioDeviceEnumerator.defaultOutputDeviceID()
      .flatMap { AudioDeviceEnumerator.transportLabel(for: $0) } ?? "unknown"

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
