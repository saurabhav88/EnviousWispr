import CoreAudio

/// A pure, per-recording OBSERVATION of the resolver's route decision, derived
/// into the low-cardinality transport facts the telemetry layer emits (#1376,
/// Bluetooth-capture epic Phase 1). Never a control input — nothing branches
/// capture on it; both sinks (`dictation.completed` PostHog + `SentryAudioExtras`)
/// read this one value instead of re-deriving from raw inputs
/// (`telemetry-observes-resolved-value-deny-by-default`).
///
/// `routeResolutionSource` is the constant `"app_derived"` this phase: the value
/// reflects the app-side resolver DECISION, not a helper-observed hardware
/// binding. Phase 3 introduces `"helper_reported"` when the truly device-bound
/// transport crosses the capture-helper seam.
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
  /// `unknown` reserved. Separates the trust-breach cohort (explicit BT pick
  /// forced to built-in) from the endorsed-policy cohort (Auto → built-in).
  public let inputSelectionMode: String
  /// Transport of the current default OUTPUT device (`"unknown"` if unreadable).
  /// The forced-built-in workaround only triggers under Bluetooth output.
  public let outputTransport: String
  /// How the value was obtained: `"app_derived"` this phase.
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
    selectedInputDeviceUID: String
  ) -> ResolvedRouteTransports {
    // The user's effective device pick: an explicit override wins, else the
    // stored selection, else empty (Auto / system default).
    let selectedUID =
      preferredInputDeviceIDOverride.isEmpty
      ? selectedInputDeviceUID : preferredInputDeviceIDOverride
    let selectionMode = selectedUID.isEmpty ? "auto" : "explicit"

    let selected =
      selectedUID.isEmpty
      ? "unknown"
      : (AudioDeviceEnumerator.transportLabel(forUID: selectedUID) ?? "unknown")

    let effective: String
    switch decision.sourceType {
    case .captureSession:
      // The capture-session path opens the built-in mic only today (bible R4).
      effective = "built_in"
    case .audioEngine:
      // Mirror AVAudioEngineSource's device resolution exactly: the pinned
      // device if it resolves to a connected device, ELSE the system-default
      // input (`AVAudioEngineSource.swift:243` — `resolvedDeviceID ??
      // defaultInputDeviceID()`). A saved-but-disconnected pinned UID therefore
      // reports the default input transport the engine actually opens, not
      // "unknown"; `selected` still stays "unknown" (the pick is unavailable).
      if !selectedUID.isEmpty, let label = AudioDeviceEnumerator.transportLabel(forUID: selectedUID)
      {
        effective = label
      } else if let defaultID = AudioDeviceEnumerator.defaultInputDeviceID() {
        effective = AudioDeviceEnumerator.transportLabel(for: defaultID) ?? "unknown"
      } else {
        effective = "unknown"
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
      routeResolutionSource: "app_derived"
    )
  }
}
