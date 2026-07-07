import EnviousWisprCore
import Foundation

/// Shared builder for the Sentry `extra` dictionary on heart-path audio events.
/// Ensures both pipelines, the XPC proxy emission site, and the former root state
/// interruption callback produce consistent tag shapes.
@MainActor
public enum SentryAudioExtras {

  /// Build the common extras dictionary attached to every heart-path audio
  /// captureError. Callers pass a stall context when the emission originated
  /// from the liveness watchdog; otherwise nil. `polishModelSwapMs` is nil
  /// when the polish subsystem has never observed a swap since launch.
  public static func buildCaptureExtras(
    route: String,
    sourceType: String,
    sessionID: UInt64,
    isActivelyCapturing: Bool,
    inputDeviceUIDPreferred: String?,
    inputDeviceUIDSystemDefault: String?,
    failureMode: String,
    stallContext: CaptureStallContext? = nil,
    polishModelSwapMs: Int? = nil,
    timeSinceLastSuccessfulRecordingMs: Int? = nil,
    configChangeCountSinceLaunch: Int? = nil,
    selectedTransport: String? = nil,
    effectiveTransport: String? = nil,
    routeReason: String? = nil,
    routeFallbackReason: String? = nil,
    inputSelectionMode: String? = nil,
    outputTransport: String? = nil,
    routeResolutionSource: String? = nil
  ) -> [String: Any] {
    var extras: [String: Any] = [
      "capture.source_type": sourceType,
      "capture.route": route,
      "capture.failure_mode": failureMode,
      "capture.is_actively_capturing": isActivelyCapturing,
      "capture_session_id": Int(sessionID),
    ]
    let normalizedPreferredUID = normalizeDeviceUID(inputDeviceUIDPreferred)
    let normalizedSystemDefaultUID = normalizeDeviceUID(inputDeviceUIDSystemDefault)
    let preferredInputSet = normalizedPreferredUID != nil
    let inputDeviceDivergence =
      normalizedPreferredUID != nil
      && normalizedSystemDefaultUID != nil
      && normalizedPreferredUID != normalizedSystemDefaultUID

    extras["capture.input_device_uid_preferred"] = normalizedPreferredUID ?? NSNull()
    extras["capture.input_device_uid_system_default"] = normalizedSystemDefaultUID ?? NSNull()
    extras["capture.preferred_input_set"] = preferredInputSet
    extras["capture.input_device_divergence"] = inputDeviceDivergence

    if let ctx = stallContext {
      extras["capture.stall.armed_at_uptime_ns"] = Int(ctx.armedAtUptimeNs)
      extras["capture.stall.fired_at_uptime_ns"] = Int(ctx.firedAtUptimeNs)
      extras["capture.stall.window_ms"] =
        Int((ctx.firedAtUptimeNs &- ctx.armedAtUptimeNs) / 1_000_000)
      extras["capture.engine_started_successfully"] = ctx.engineStartedSuccessfully
      extras["capture.tap_installed"] = ctx.tapInstalled
      extras["capture.format_mismatch"] = ctx.formatMismatchObserved
    }

    if let swap = polishModelSwapMs {
      extras["polish.recent_model_swap_ms"] = swap
    }

    if let ms = timeSinceLastSuccessfulRecordingMs {
      extras["capture.time_since_last_successful_recording_ms"] = ms
    }

    if let count = configChangeCountSinceLaunch {
      extras["capture.config_change_count_since_launch"] = count
    }

    // #1376: effective-device route context on capture-error events. Absent
    // params → keys omitted (mirrors the optional-extras pattern above). Low-
    // cardinality transport/reason strings only (`telemetry-privacy-boundary`);
    // `capture.effective_transport` is the app-derived value, NOT a helper-bound
    // "actual started" transport (that name is reserved for Phase 3).
    if let st = selectedTransport { extras["capture.selected_transport"] = st }
    if let et = effectiveTransport { extras["capture.effective_transport"] = et }
    if let rr = routeReason { extras["capture.route_reason"] = rr }
    if let rfr = routeFallbackReason { extras["capture.route_fallback_reason"] = rfr }
    if let ism = inputSelectionMode { extras["capture.input_selection_mode"] = ism }
    if let ot = outputTransport { extras["capture.output_transport"] = ot }
    if let rrs = routeResolutionSource { extras["capture.route_resolution_source"] = rrs }

    return extras
  }

  private static func normalizeDeviceUID(_ uid: String?) -> String? {
    guard let uid, !uid.isEmpty else { return nil }
    return uid
  }
}
