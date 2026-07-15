import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Owns the SHARED heart-path infrastructure-failure telemetry that previously
/// lived duplicated across the old Parakeet pipeline and `WhisperKitPipeline`.
///
/// Five events:
///   1. capture stall (watchdog-fired)
///   2. XPC reply failure (proxy-side)
///   3. capture session interruption (route-change / runtime error)
///   4. no audio captured (rawSamples-empty terminal branch)
///   5. zombie zero-peak (peak == 0 with non-empty samples — issue #302)
///
/// Engine-internal telemetry (Parakeet streaming, MLX kernels; WhisperKit
/// language detection, batch failures, model load) is NOT moved here by
/// design — those events stay in their owning pipeline. See `#290` plan.
///
/// Sentry payload shapes (category, tags, extras keys, breadcrumb messages)
/// are reproduced exactly from the prior in-pipeline implementations so the
/// triage Routine that polls Sentry every 4 hours continues filing GitHub
/// issues with stable grouping.
///
/// The Sentry sink is injected as a closure callback rather than a protocol
/// to avoid existential dispatch on a `@MainActor` hot path, keeping the
/// emitter concrete and the test seam recording-closure-shaped.
@MainActor
final class HeartPathTelemetryEmitter {

  // MARK: - Sinks (closure-based; default wires SentryBreadcrumb)

  typealias CaptureErrorSink = @MainActor (
    _ error: any Error,
    _ category: SentryBreadcrumb.ErrorCategory,
    _ stage: String,
    _ extra: [String: Any]?
  ) -> Void

  typealias BreadcrumbSink = @MainActor (
    _ stage: String,
    _ message: String,
    _ data: [String: Any]?
  ) -> Void

  // MARK: - Identity & dependencies

  /// Backend that owns this emitter. Used to preserve the historical
  /// asymmetry where WhisperKit's capture-interruption extra carried
  /// `"backend": "whisperKit"` while Parakeet's did not.
  private let backend: ASRBackendType
  private let captureTelemetry: CaptureTelemetryState
  private let captureError: CaptureErrorSink
  private let addBreadcrumb: BreadcrumbSink

  // MARK: - Per-session dedup state

  /// One Sentry event per (session, failure mode) even though the stall
  /// watchdog and the rawSamples-empty branch both observe the same session.
  /// A `Set` (not a single Bool, #1317 PR1) so a later failure mode for the
  /// same session — e.g. `becameZeroMidCapture` after an earlier `noBuffers`
  /// — is not hidden by the first mode's dedup. Reset on session-id change.
  private var capturedStallModes: Set<CaptureStallFailureMode> = []
  private var lastObservedCaptureSession: UInt64 = 0

  init(
    backend: ASRBackendType,
    captureTelemetry: CaptureTelemetryState,
    captureError: @escaping CaptureErrorSink = { error, category, stage, extra in
      SentryBreadcrumb.captureError(error, category: category, stage: stage, extra: extra)
    },
    addBreadcrumb: @escaping BreadcrumbSink = { stage, message, data in
      SentryBreadcrumb.add(stage: stage, message: message, level: .warning, data: data)
    }
  ) {
    self.backend = backend
    self.captureTelemetry = captureTelemetry
    self.captureError = captureError
    self.addBreadcrumb = addBreadcrumb
  }

  // MARK: - Events

  /// Emit `audio_capture_stalled` once per session. Subsequent calls within
  /// the same session are dropped silently (dedup).
  /// Returns true if the event fired (caller may chain terminal-state work).
  @discardableResult
  func stallFired(
    ctx: CaptureStallContext,
    isActivelyCapturing: Bool
  ) -> Bool {
    resetIfNewSession(ctx.sessionID)
    guard capturedStallModes.insert(ctx.failureMode).inserted else { return false }

    let extras = SentryAudioExtras.buildCaptureExtras(
      route: ctx.route,
      sourceType: ctx.sourceType,
      sessionID: ctx.sessionID,
      isActivelyCapturing: isActivelyCapturing,
      inputDeviceUIDPreferred: ctx.inputDeviceUIDPreferred,
      inputDeviceUIDSystemDefault: ctx.inputDeviceUIDSystemDefault,
      failureMode: ctx.failureMode.rawValue,
      stallContext: ctx,
      selectedTransport: ctx.selectedTransport,
      effectiveTransport: ctx.effectiveTransport,
      routeReason: ctx.routeReason,
      routeFallbackReason: ctx.routeFallbackReason,
      inputSelectionMode: ctx.inputSelectionMode,
      outputTransport: ctx.outputTransport,
      routeResolutionSource: ctx.routeResolutionSource
    )
    captureError(
      HeartPathError.audioCaptureStalled(sessionID: ctx.sessionID, ctx: ctx),
      .audioCaptureStalled,
      "recording",
      extras
    )
    return true
  }

  /// Emit either a deduped breadcrumb (if a stall already fired for this
  /// session) or a terminal `no_audio_captured` captureError. Mirrors the prior
  /// in-pipeline `emitNoAudioCapturedEvent` call sites.
  func noAudioCaptured(ctx: NoAudioContext) {
    resetIfNewSession(ctx.sessionID)
    if !capturedStallModes.isEmpty {
      addBreadcrumb(
        "recording",
        dedupedBreadcrumbMessage,
        [
          "deduped_from": "audio_capture_stalled",
          "capture_session_id": Int(ctx.sessionID),
        ]
      )
      return
    }
    let err = HeartPathError.noAudioCaptured(
      sessionID: ctx.sessionID,
      durationMs: ctx.durationMs,
      wasStreaming: ctx.wasStreaming,
      route: ctx.route
    )
    var extras = SentryAudioExtras.buildCaptureExtras(
      route: ctx.route,
      sourceType: ctx.captureSourceType,
      sessionID: ctx.sessionID,
      isActivelyCapturing: ctx.isActivelyCapturing,
      inputDeviceUIDPreferred: ctx.inputDeviceUIDPreferred,
      inputDeviceUIDSystemDefault: ctx.inputDeviceUIDSystemDefault,
      failureMode: "no_audio_captured",
      selectedTransport: ctx.selectedTransport,
      effectiveTransport: ctx.effectiveTransport,
      routeReason: ctx.routeReason,
      routeFallbackReason: ctx.routeFallbackReason,
      inputSelectionMode: ctx.inputSelectionMode,
      outputTransport: ctx.outputTransport,
      routeResolutionSource: ctx.routeResolutionSource
    )
    // #1434: post-stop capture-health on the no-audio terminal (absent → keys
    // omitted, matching the optional-extras pattern).
    if let rate = ctx.captureNativeRateHz { extras["capture.native_rate_hz"] = rate }
    if let drops = ctx.captureRingDropCount { extras["capture.ring_drop_count"] = drops }
    if let errs = ctx.captureConverterErrorCount {
      extras["capture.converter_error_count"] = errs
    }
    if let zeros = ctx.captureZeroOutputCount { extras["capture.zero_output_count"] = zeros }
    if let div = ctx.captureRateDivergenceDetected {
      extras["capture.rate_divergence_detected"] = div
    }
    if let stab = ctx.captureFormatStabilized { extras["capture.format_stabilized"] = stab }
    if let rebuilt = ctx.captureRebuiltForFormat {
      extras["capture.rebuilt_for_format"] = rebuilt
    }
    if let channels = ctx.captureNativeChannelCount {
      extras["capture.native_channel_count"] = channels
    }
    captureError(err, .audioCaptureFailed, "recording", extras)
  }

  /// Emit `zombie_engine_zero_peak` when the VAD gate gets a full recording
  /// of exactly-zero audio with non-empty samples (matches the zombie-engine
  /// failure described in `gotchas.md`). Dedupes via shared
  /// `CaptureTelemetryState`. Returns true iff an event fired.
  ///
  /// Invariant: `markZombieEmitted` is called UNCONDITIONALLY before the
  /// `shouldEmit` guard so the 30s dedup window slides forward on every
  /// observation, not just on emissions. Rapid retries from the same route
  /// stay suppressed instead of slipping through after the first emit's
  /// window expires. See `CaptureTelemetryState.markZombieEmitted` doc
  /// comment.
  @discardableResult
  func zombieZeroPeak(ctx: ZeroPeakContext) -> Bool {
    let shouldEmit = captureTelemetry.shouldEmitZombie(
      route: ctx.route, window: .seconds(30))
    captureTelemetry.markZombieEmitted(route: ctx.route)
    guard shouldEmit else { return false }

    let err = HeartPathError.zombieEngineZeroPeak(
      sessionID: ctx.sessionID,
      durationMs: ctx.durationMs,
      route: ctx.route,
      sampleCount: ctx.sampleCount
    )
    captureError(
      err,
      .audioCaptureFailed,
      "recording",
      SentryAudioExtras.buildCaptureExtras(
        route: ctx.route,
        sourceType: ctx.captureSourceType,
        sessionID: ctx.sessionID,
        isActivelyCapturing: ctx.isActivelyCapturing,
        inputDeviceUIDPreferred: ctx.inputDeviceUIDPreferred,
        inputDeviceUIDSystemDefault: ctx.inputDeviceUIDSystemDefault,
        failureMode: "zombie_engine_zero_peak",
        timeSinceLastSuccessfulRecordingMs:
          captureTelemetry.timeSinceLastSuccessfulRecordingMs(),
        selectedTransport: ctx.selectedTransport,
        effectiveTransport: ctx.effectiveTransport,
        routeReason: ctx.routeReason,
        routeFallbackReason: ctx.routeFallbackReason,
        inputSelectionMode: ctx.inputSelectionMode,
        outputTransport: ctx.outputTransport,
        routeResolutionSource: ctx.routeResolutionSource
      )
    )
    return true
  }

  /// Heartpath 5b (#1520): a zero-signal take invoked the retire primitive.
  /// Fans out to a content-free Sentry breadcrumb (context on a LATER Sentry
  /// event — creates no new issue/alert) AND the countable PostHog event.
  /// `ms_since_last_good` is filled here from the shared `captureTelemetry`.
  func deadMicRetireAttempted(ctx: DeadMicRetireAttemptContext) {
    // Compute once so the breadcrumb and the PostHog event carry an identical
    // payload — the breadcrumb is the forensic trail beside a LATER Sentry
    // incident, so it must not omit fields PostHog gets (optional keys omitted
    // when absent, matching the optional-extras pattern).
    let msSinceLastGood = captureTelemetry.timeSinceLastSuccessfulRecordingMs()
    var breadcrumb: [String: Any] = [
      "transport": ctx.transport,
      "failure_shape": ctx.failureShape,
      "retire_action": ctx.retireAction,
      "health_guess_refused": ctx.healthGuessRefused,
      "warm_policy": ctx.warmPolicy,
    ]
    if let selectedTransport = ctx.selectedTransport {
      breadcrumb["selected_transport"] = selectedTransport
    }
    if let routeFallbackReason = ctx.routeFallbackReason {
      breadcrumb["route_fallback_reason"] = routeFallbackReason
    }
    if let msSinceLastGood { breadcrumb["ms_since_last_good"] = msSinceLastGood }
    addBreadcrumb("recording", "Dead mic retire attempted", breadcrumb)
    TelemetryService.shared.deadMicRetireAttempted(
      transport: ctx.transport,
      selectedTransport: ctx.selectedTransport,
      failureShape: ctx.failureShape,
      healthGuessRefused: ctx.healthGuessRefused,
      warmPolicy: ctx.warmPolicy,
      retireAction: ctx.retireAction,
      msSinceLastGood: msSinceLastGood,
      routeFallbackReason: ctx.routeFallbackReason)
  }

  /// Heartpath 5b (#1520): a pending dead-mic watch resolved (a later take
  /// recovered, or retired again). Same content-free breadcrumb + PostHog
  /// fan-out. The outcome value is produced by `CaptureTelemetryState`.
  func deadMicRecovered(outcome: DeadMicRecoveryOutcome) {
    addBreadcrumb(
      "recording",
      "Dead mic recovery observed",
      [
        "recovered": outcome.recovered,
        "resolution": outcome.resolution,
        "retire_shape": outcome.retireShape,
        "retire_transport": outcome.retireTransport,
        "recovery_transport": outcome.recoveryTransport,
        "transport_changed": outcome.transportChanged,
        "gap_ms": outcome.gapMs,
      ])
    TelemetryService.shared.deadMicRecovery(
      recovered: outcome.recovered,
      resolution: outcome.resolution,
      retireShape: outcome.retireShape,
      retireTransport: outcome.retireTransport,
      recoveryTransport: outcome.recoveryTransport,
      transportChanged: outcome.transportChanged,
      gapMs: outcome.gapMs)
  }

  // MARK: - Private

  /// Per-backend breadcrumb message text. Preserves the historical asymmetry
  /// where WhisperKit's deduped breadcrumb included the backend tag.
  private var dedupedBreadcrumbMessage: String {
    switch backend {
    case .parakeet: return "No audio captured (deduped)"
    case .whisperKit: return "No audio captured (WhisperKit, deduped)"
    }
  }

  private func resetIfNewSession(_ sessionID: UInt64) {
    guard sessionID != lastObservedCaptureSession else { return }
    lastObservedCaptureSession = sessionID
    capturedStallModes.removeAll()
  }
}
