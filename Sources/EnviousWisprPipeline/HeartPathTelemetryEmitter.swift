import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Owns the SHARED heart-path infrastructure-failure telemetry that previously
/// lived duplicated across `TranscriptionPipeline` and `WhisperKitPipeline`.
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
/// issues with stable grouping. See `.claude/knowledge/sentry-triage-pipeline.md`.
///
/// The Sentry sink is injected as a closure callback rather than a protocol
/// (per `feedback_no_actor_protocol_existential_hot_path.md`), keeping the
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
  /// asymmetry where WhisperKit's `captureSessionInterruption` extra carried
  /// `"backend": "whisperKit"` while Parakeet's did not.
  private let backend: ASRBackendType
  private let captureTelemetry: CaptureTelemetryState
  private let captureError: CaptureErrorSink
  private let addBreadcrumb: BreadcrumbSink

  // MARK: - Per-session dedup state

  /// One Sentry event per wedge incident even though the stall watchdog and
  /// the rawSamples-empty branch both observe the same session. Reset on
  /// session-id change.
  private var stallEventAlreadyCaptured: Bool = false
  private var lastObservedCaptureSession: UInt64 = 0
  /// Set when the proxy's reply-path swallowed an XPC failure. The
  /// rawSamples-empty branch dedups against this so we emit
  /// `xpc_service_error` once instead of also firing `no_audio_captured`
  /// for the same incident.
  private var xpcReplyFailedThisSession: Bool = false

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
    guard !stallEventAlreadyCaptured else { return false }
    stallEventAlreadyCaptured = true

    let extras = SentryAudioExtras.buildCaptureExtras(
      route: ctx.route,
      sourceType: ctx.sourceType,
      sessionID: ctx.sessionID,
      isActivelyCapturing: isActivelyCapturing,
      inputDeviceUIDPreferred: ctx.inputDeviceUIDPreferred,
      inputDeviceUIDSystemDefault: ctx.inputDeviceUIDSystemDefault,
      failureMode: "stall_window_elapsed",
      stallContext: ctx
    )
    captureError(
      HeartPathError.audioCaptureStalled(sessionID: ctx.sessionID, ctx: ctx),
      .audioCaptureStalled,
      "recording",
      extras
    )
    return true
  }

  /// Emit `xpc_service_error`. Marks the session so a subsequent rawSamples-empty
  /// branch dedups to a breadcrumb instead of a duplicate captureError.
  func xpcReplyFailed(ctx: XPCReplyFailureContext) {
    resetIfNewSession(ctx.sessionID)
    xpcReplyFailedThisSession = true
    captureError(
      HeartPathError.xpcReplyFailed(ctx: ctx),
      .xpcServiceError,
      "audio",
      [
        "xpc.reply_stage": ctx.replyStage,
        "xpc.error_domain": ctx.errorDomain,
        "xpc.error_code": ctx.errorCode,
        "capture_session_id": Int(ctx.sessionID),
      ]
    )
  }

  /// Emit `audio_capture_failed` for a capture-session interruption. Backend
  /// extra preserved exactly as it was per pipeline (WhisperKit included it,
  /// Parakeet did not).
  func captureSessionInterrupted(ctx: CaptureSessionInterruptionContext) {
    var extra: [String: Any] = [
      "capture_session.kind": ctx.kind.rawValue,
      "capture_session.reason_code": ctx.reasonCode.map { $0 } ?? NSNull(),
      "capture_session.reason_label": ctx.reasonLabel ?? NSNull(),
      "capture_session.error_domain": ctx.errorDomain ?? NSNull(),
      "capture_session.error_code": ctx.errorCode.map { $0 } ?? NSNull(),
      "capture_session.error_description": ctx.errorDescription ?? NSNull(),
      "capture.is_actively_capturing": ctx.isActivelyCapturing,
      "capture_session_id": Int(ctx.sessionID),
    ]
    // Historical asymmetry — only WhisperKit's interruption carried the
    // backend extra. Preserve to keep Sentry grouping/triage stable.
    if backend == .whisperKit {
      extra["backend"] = backend.rawValue
    }
    captureError(
      HeartPathError.captureSessionInterrupted(ctx: ctx),
      .audioCaptureFailed,
      "audio",
      extra
    )
  }

  /// Emit either a deduped breadcrumb (if a stall or XPC failure already
  /// fired for this session) or a terminal `no_audio_captured` captureError.
  /// Mirrors the prior in-pipeline `emitNoAudioCapturedEvent` call sites.
  func noAudioCaptured(ctx: NoAudioContext) {
    resetIfNewSession(ctx.sessionID)
    if stallEventAlreadyCaptured || xpcReplyFailedThisSession {
      let dedupedFrom =
        stallEventAlreadyCaptured ? "audio_capture_stalled" : "xpc_reply_failed"
      addBreadcrumb(
        "recording",
        dedupedBreadcrumbMessage,
        [
          "deduped_from": dedupedFrom,
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
        failureMode: "no_audio_captured"
      )
    )
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
        configChangeCountSinceLaunch: captureTelemetry.configurationChangeCount
      )
    )
    return true
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
    stallEventAlreadyCaptured = false
    xpcReplyFailedThisSession = false
  }
}
