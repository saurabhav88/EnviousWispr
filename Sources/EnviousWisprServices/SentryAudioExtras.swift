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
    selectedTransport: String? = nil,
    effectiveTransport: String? = nil,
    routeReason: String? = nil,
    routeFallbackReason: String? = nil,
    inputSelectionMode: String? = nil,
    outputTransport: String? = nil,
    routeResolutionSource: String? = nil,
    inputResolutionSource: String? = nil
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
      // #1434 capture-health at stall time. Source-stamped rate/divergence
      // (nil on proxy-origin stalls — the host watchdog can't read helper
      // state pre-stop); kernel-merged stabilization flags. Never counters
      // (those exist only post-stop).
      if let rate = ctx.nativeRateHz { extras["capture.native_rate_hz"] = rate }
      if let div = ctx.rateDivergenceDetected {
        extras["capture.rate_divergence_detected"] = div
      }
      if let stab = ctx.formatStabilized { extras["capture.format_stabilized"] = stab }
      if let rebuilt = ctx.captureRebuiltForFormat {
        extras["capture.rebuilt_for_format"] = rebuilt
      }
      if let channels = ctx.nativeChannelCount {
        extras["capture.native_channel_count"] = channels
      }
    }

    if let swap = polishModelSwapMs {
      extras["polish.recent_model_swap_ms"] = swap
    }

    if let ms = timeSinceLastSuccessfulRecordingMs {
      extras["capture.time_since_last_successful_recording_ms"] = ms
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
    // #1714: WHY the input device was selected. Deliberately NOT named
    // `resolution_source`: `route_resolution_source` above already carries
    // `app_derived` / `helper_reported`, which is how a TRANSPORT LABEL was
    // derived — an unrelated question. Two near-identical keys on one event
    // would make every future query ambiguous. Nil omits the key entirely.
    if let irs = inputResolutionSource { extras["capture.input_resolution_source"] = irs }

    return extras
  }

  /// The extras that are ALSO promoted to per-event Sentry TAGS.
  ///
  /// Sentry cannot group or filter on `extra`, so a field that lives only there
  /// can be read one event at a time and never aggregated. #2021: that is why
  /// "what is the transport split on the fixed release" — the question that
  /// decides whether #1810's transport-gated fix worked — was unanswerable. The
  /// only axis available was `audio.route`, which is a proxy: a route is not a
  /// transport, and it cannot separate `all_zero_from_start` from
  /// `became_zero_mid_capture` at all, which is the exact distinction #1788 and
  /// #1578 were split along.
  ///
  /// **Per-EVENT, not scope.** `audio.route` is a scope tag
  /// (`SentryBreadcrumb.swift`) because a route is a session property. These two
  /// describe the FAILURE — the transport bound for that attempt and the shape
  /// it failed in — so a scope tag would go stale and mis-attribute the NEXT
  /// event. `captureError`'s existing `tags:` parameter is already per-event.
  ///
  /// **A missing value produces NO key.** Never `""` and never `"nil"`: an
  /// empty-string bucket is the exact trap #2021 reports, where aggregating on
  /// `input_device_transport` returned a single empty bucket that was the
  /// instrument rather than the data.
  ///
  /// Both vocabularies are closed and small — `CaptureStallFailureMode` has
  /// three cases, and `AudioDeviceManager.transportLabel(forTransportType:)` is
  /// an exhaustive switch over CoreAudio transport constants — so neither can
  /// blow up tag cardinality. Categories only, never content, so the telemetry
  /// privacy boundary is unaffected.
  ///
  /// Reads the SAME keys `buildCaptureExtras` writes, deliberately: a second
  /// vocabulary here would be able to drift from the payload it describes.
  public static func promotedTags(from extras: [String: Any]?) -> [String: String] {
    guard let extras else { return [:] }
    var tags: [String: String] = [:]
    for key in promotedTagKeys {
      // Only a real String is promoted. A non-String value is SKIPPED rather
      // than stringified — a coerced tag would be a value no query could ever
      // match, which is worse than an absent one.
      if let value = extras[key] as? String, !value.isEmpty {
        tags[key] = value
      }
    }
    return tags
  }

  /// The promotion list. One place, so the two default sinks cannot disagree.
  static let promotedTagKeys = ["capture.effective_transport", "capture.failure_mode"]

  private static func normalizeDeviceUID(_ uid: String?) -> String? {
    guard let uid, !uid.isEmpty else { return nil }
    return uid
  }
}
