import Foundation

/// Discriminates why a capture-stall watchdog fired. `.noBuffers` is today's
/// only producer (no audio buffers arrived before the watchdog window
/// elapsed); `.allZeroFromStart` and `.becameZeroMidCapture` are added by
/// #1317 PR2 for the "device running but feeding all-zero audio" harness
/// glitch, distinct from a genuinely dead/muted/removed device. String-backed
/// so the raw value doubles as the Sentry wire value — `.noBuffers` keeps
/// today's literal string (`"stall_window_elapsed"`) so PR1 introduces zero
/// telemetry change.
public enum CaptureStallFailureMode: String, Sendable, Hashable {
  case noBuffers = "stall_window_elapsed"
  case allZeroFromStart = "all_zero_from_start"
  case becameZeroMidCapture = "became_zero_mid_capture"
}

/// Context attached to a stalled-capture telemetry event. Built by the
/// in-process capture path (`HALDeviceInputSource` / `AudioCaptureManager`) at
/// watchdog-fire time and consumed by the pipeline's emission site.
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
  /// Why the watchdog fired. Required (no default) so every producer states
  /// it explicitly and the compiler catches a missed site when a new failure
  /// mode is added (#1317).
  public let failureMode: CaptureStallFailureMode
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
  /// #1523: the bound device's total native input channel count, source-stamped
  /// at watchdog-fire time (direct HAL stalls populate it; the XPC proxy's
  /// host-side watchdog leaves it nil). Preserved through `enrichedWithStabilizationFlags`.
  public let nativeChannelCount: Int?

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
    failureMode: CaptureStallFailureMode,
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
    captureRebuiltForFormat: Bool? = nil,
    nativeChannelCount: Int? = nil
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
    self.failureMode = failureMode
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
    self.nativeChannelCount = nativeChannelCount
  }

  /// #1543 in-process forward enrichment: the capture MANAGER owns the
  /// app-lifetime session id and the resolved route decision; the HAL source
  /// (which builds this context) sees neither — its `captureGeneration` resets
  /// per source instance and it only knows `route: "hal_device_input"`. The
  /// manager overlays its session id (so the event carries the SAME id the
  /// pipeline dedup + `isCurrentSession` filter key on, app-lifetime unique like
  /// the deleted proxy's counter) and its frozen route decision (so a built-in
  /// vs Bluetooth stall lands in the right route bucket with transport/reason
  /// detail). Source-stamped health fields (rate/divergence/channels/device
  /// UIDs) are preserved as-is. Transport strings are passed individually rather
  /// than as `ResolvedRouteTransports` to keep this Core type dependency-free.
  public func enrichedWithManagerRoute(
    sessionID: UInt64,
    route: String,
    selectedTransport: String?,
    effectiveTransport: String?,
    routeReason: String?,
    routeFallbackReason: String?,
    inputSelectionMode: String?,
    outputTransport: String?,
    routeResolutionSource: String?
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
      failureMode: failureMode,
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
      captureRebuiltForFormat: captureRebuiltForFormat,
      nativeChannelCount: nativeChannelCount
    )
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
      failureMode: failureMode,
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
      captureRebuiltForFormat: captureRebuiltForFormat,
      nativeChannelCount: nativeChannelCount
    )
  }
}
