import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Renders `KernelLifecycleEvent` values (produced by
/// `KernelHeartPathTelemetryObserver`) into the byte-identical Sentry / PostHog
/// calls that the old Parakeet pipeline made today. PR-4b.2 §3.7.
///
/// Backend-agnostic — the backend tag flows from `init(backend:)`, never from
/// hardcoded `"parakeet"` / `"whisperKit"` strings inside the switch body.
/// Two factory call sites (PR-4b.2 today; PR-5/PR-6 unify) decide the
/// per-engine value.
///
/// All sinks are closure-injected so tests inspect emissions without touching
/// the real Sentry / PostHog SDKs (same pattern as `HeartPathTelemetryEmitter`).
///
/// **Engine-internal events stay where they live today.** PR-1 §B.7.4 covers
/// the kernel-owned vocabulary; engine-internal telemetry (Parakeet streaming,
/// WhisperKit language detection, etc.) remains in its owning pipeline and
/// will move in PR-5 / PR-6.
@MainActor
final class KernelLifecycleTelemetrySink {

  // MARK: Sinks (closure-injected; default wires real SDK calls)

  /// All sink-emitted breadcrumbs are info-level (matches old TP call sites);
  /// the level is fixed in the default closure rather than exposed in the
  /// typealias so this module doesn't have to import Sentry directly
  /// (`SentryLevel` lives behind `EnviousWisprServices`'s Sentry wrapper).
  typealias BreadcrumbSink = @MainActor (
    _ stage: String, _ message: String, _ data: [String: Any]?
  ) -> Void

  typealias RecordingStateSink = @MainActor (
    _ active: Bool, _ backend: String?, _ isStreaming: Bool?
  ) -> Void

  typealias AudioRouteSink = @MainActor (_ route: String) -> Void

  typealias DictationInvokedSink = @MainActor (
    _ triggerSource: String, _ inputMode: String, _ targetApp: String?
  ) -> Void

  typealias ModelLoadWedgedSink = @MainActor (_ backend: String) -> Void

  typealias CaptureErrorSink = @MainActor (
    _ error: any Error,
    _ category: SentryBreadcrumb.ErrorCategory,
    _ stage: String,
    _ extra: [String: Any]?
  ) -> Void

  // MARK: Identity + read sources

  private let backend: ASRBackendType
  private let audioCapture: any AudioCaptureInterface
  private let context: KernelSessionContext
  private let captureTelemetry: CaptureTelemetryState
  private let breadcrumb: BreadcrumbSink
  private let updateRecordingState: RecordingStateSink
  private let updateAudioRoute: AudioRouteSink
  private let dictationInvoked: DictationInvokedSink
  private let modelLoadWedged: ModelLoadWedgedSink
  private let captureError: CaptureErrorSink

  init(
    backend: ASRBackendType,
    audioCapture: any AudioCaptureInterface,
    context: KernelSessionContext,
    captureTelemetry: CaptureTelemetryState,
    breadcrumb: @escaping BreadcrumbSink = { stage, message, data in
      SentryBreadcrumb.add(stage: stage, message: message, level: .info, data: data)
    },
    updateRecordingState: @escaping RecordingStateSink = { active, backend, isStreaming in
      SentryBreadcrumb.updateRecordingState(
        active: active, backend: backend, isStreaming: isStreaming)
    },
    updateAudioRoute: @escaping AudioRouteSink = { route in
      SentryBreadcrumb.updateAudioRoute(route)
    },
    dictationInvoked: @escaping DictationInvokedSink = { trigger, mode, target in
      TelemetryService.shared.dictationInvoked(
        triggerSource: trigger, inputMode: mode, targetApp: target)
    },
    modelLoadWedged: @escaping ModelLoadWedgedSink = { backend in
      // Minimal payload — the full wedge_snapshot is documented as deferred
      // (§2.2 non-goals). PR-4b.4 Live UAT may file a follow-up.
      TelemetryService.shared.modelLoadWedged(
        backend: backend, stage: "loading_model",
        silenceMs: 0, observedMaxGapMs: 0, observedPhase: "kernel",
        signalCountTotal: 0, firstSignalLatencyMs: nil, totalAttemptDurationMs: 0)
    },
    captureError: @escaping CaptureErrorSink = { error, category, stage, extra in
      SentryBreadcrumb.captureError(error, category: category, stage: stage, extra: extra)
    }
  ) {
    self.backend = backend
    self.audioCapture = audioCapture
    self.context = context
    self.captureTelemetry = captureTelemetry
    self.breadcrumb = breadcrumb
    self.updateRecordingState = updateRecordingState
    self.updateAudioRoute = updateAudioRoute
    self.dictationInvoked = dictationInvoked
    self.modelLoadWedged = modelLoadWedged
    self.captureError = captureError
  }

  /// Switch over the 12-case lifecycle vocabulary and emit each PR-1 §B.7.2
  /// kernel-owned event with byte-identical event identity
  /// (stage / message / category / event name). Payload fidelity per §3.7
  /// mapping table — preserved where the sink can read, deferred where rich
  /// kernel-side wiring would be required (§2.2 non-goals).
  func emit(_ event: KernelLifecycleEvent) {
    switch event {
    case .modelLoading:
      breadcrumb("asr", "Model loading", ["backend": backend.rawValue])

    case .recordingCommitted(let isStreaming):
      let triggerSource = context.config?.triggerSource.rawValue ?? "unknown"
      let inputMode = context.config?.inputMode.rawValue ?? "unknown"
      let targetApp = context.targetApp?.localizedName
      dictationInvoked(triggerSource, inputMode, targetApp)
      // Mirror old TP:546-553 — the breadcrumb data dict carries both
      // `backend` and `streaming`, and `updateRecordingState` carries the
      // real streaming flag (Codex review #11 r2 — earlier draft hardcoded
      // `false` and would have misreported every streaming session as batch).
      breadcrumb(
        "recording", "Recording started",
        ["backend": backend.rawValue, "streaming": isStreaming])
      updateRecordingState(true, backend.rawValue, isStreaming)
      updateAudioRoute(audioCapture.currentAudioRoute)

    case .recordingStopped:
      breadcrumb("recording", "Recording stopped", nil)
      updateRecordingState(false, nil, nil)

    case .transcriptionStarted:
      breadcrumb("asr", "Transcription started", ["backend": backend.rawValue])

    case .asrCompleted:
      breadcrumb("asr", "ASR completed", ["backend": backend.rawValue])

    case .pipelineCompleted:
      breadcrumb("pipeline", "Pipeline complete", ["backend": backend.rawValue])
      captureTelemetry.recordSuccessfulRecording()

    case .failed(let reason):
      emitFailed(reason)

    case .audioInterrupted:
      updateRecordingState(false, nil, nil)

    case .asrInterrupted(let wasRecording):
      // Bridge matrix #3 — old TP:1145 emitted `was_recording == state == .recording`
      // at crash time. The kernel reaches `.asrInterrupted` from `.recording`
      // OR `.transcribing`; the observer threads the prior state in here.
      captureError(
        NSError(
          domain: "EnviousWispr", code: -3,
          userInfo: [NSLocalizedDescriptionKey: "ASR XPC service crashed"]),
        .xpcServiceError, "asr",
        ["was_recording": wasRecording])
      updateRecordingState(false, nil, nil)

    case .discarded(let reason):
      // PR-1 §B.7.4 — the ONE new event the epic introduces. Old code was
      // silent for short recordings (TP:634). Sink emits a breadcrumb
      // carrying the abort reason so the timeline names which abort path
      // fired. Rich Sentry event design belongs to a later epic PR.
      breadcrumb(
        "recording", "Recording discarded",
        ["reason": String(describing: reason)])

    case .noSpeech(let source):
      // r7 — emit the source-appropriate breadcrumb to preserve PR-1's exact
      // name/string rule. VAD-gate path = TP:787; ASR-empty no-speech = TP:902.
      switch source {
      case .vadGate:
        breadcrumb(
          "asr", "VAD gate: no speech detected, skipping ASR",
          ["backend": backend.rawValue])
      case .asrEmptyNoSpeech:
        breadcrumb(
          "asr", "ASR empty (no speech detected)",
          ["backend": backend.rawValue])
      }

    case .cancelled:
      // r7 — NO breadcrumb. PR-1 §B.7.4 allows only ONE new event
      // (`discarded`); a `.cancelled` breadcrumb would be a second new event.
      // The kernel state observer still tracks the `.cancelled` transition —
      // only the telemetry emission is omitted.
      break
    }
  }

  /// Per-failure-reason captureError emission. Mirrors old TP failure call
  /// sites with stage + message + core data; rich diagnostic dicts deferred.
  private func emitFailed(_ reason: RecordingFailureReason) {
    switch reason {
    case .modelWedged:
      captureError(
        ModelLoadWatchdog.WedgeError(),
        .modelLoadWedged, "asr",
        ["backend": backend.rawValue])
      modelLoadWedged(backend.rawValue)
    case .modelLoadFailed:
      captureError(
        NSError(
          domain: "EnviousWispr", code: -10,
          userInfo: [NSLocalizedDescriptionKey: "Model load failed"]),
        .modelLoadFailed, "asr",
        ["backend": backend.rawValue])
    case .captureStartFailed:
      captureError(
        NSError(
          domain: "EnviousWispr", code: -11,
          userInfo: [NSLocalizedDescriptionKey: "Recording failed"]),
        .audioCaptureFailed, "recording",
        ["backend": backend.rawValue])
    case .asrEmpty:
      captureError(
        NSError(
          domain: "EnviousWispr", code: -1,
          userInfo: [
            NSLocalizedDescriptionKey: "ASR returned empty text despite speech evidence"
          ]),
        .asrEmptyResult, "asr",
        ["backend": backend.rawValue])
    case .emptyAfterProcessing:
      captureError(
        HeartPathError.emptyAfterProcessing(
          route: audioCapture.currentAudioRoute,
          wasPolishEnabled: false),  // limb-step state not threaded; conservative default
        .heartPathFinalization, "processing",
        [
          "backend": backend.rawValue,
          "capture.route": audioCapture.currentAudioRoute,
        ])
    case .storageFailed:
      captureError(
        NSError(
          domain: "EnviousWispr", code: -12,
          userInfo: [NSLocalizedDescriptionKey: "Failed to save transcript"]),
        .asrFailed, "storage", nil)
    case .asrFailed, .asrWedged:
      captureError(
        NSError(
          domain: "EnviousWispr", code: -13,
          userInfo: [NSLocalizedDescriptionKey: "Transcription failed"]),
        .asrFailed, "transcription",
        ["backend": backend.rawValue])
    case .permissionDenied:
      captureError(
        NSError(
          domain: "EnviousWispr", code: -14,
          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"]),
        .audioCaptureFailed, "recording",
        ["backend": backend.rawValue, "failure_mode": "permission_denied"])
    case .prepareFailed:
      captureError(
        NSError(
          domain: "EnviousWispr", code: -15,
          userInfo: [NSLocalizedDescriptionKey: "Prepare failed"]),
        .audioCaptureFailed, "recording",
        ["backend": backend.rawValue, "failure_mode": "prepare_failed"])
    case .captureStalled:
      // r8 (2026-05-25) — NO Sentry/PostHog emission for `.captureStalled`.
      // The rich `HeartPathTelemetryEmitter.stallFired(ctx:)` (`:91-116`)
      // already owns this terminal: it is reached via
      // `KernelHeartPathTelemetryObserver.handleCaptureStall(_:)` (`:94-100`)
      // from the App-routed `WedgeRecoveryRouter` → driver's
      // `HeartPathTelemetryTarget` conformance, with full
      // `SentryAudioExtras.buildCaptureExtras(...)` payload + per-session
      // dedup. The lifecycle event still fires (kernel state observability
      // is preserved); only the duplicate Sentry captureError is suppressed.
      //
      // Codex r8 flagged this as the convergence-escape signal: emitter
      // dedup is `private` to the emitter, so without this skip both paths
      // fire → Sentry double-counts. Skip-not-share is preferred over an
      // explicit shared dedup contract (scope creep for PR-4b.2).
      break
    case .noAudioCaptured:
      // Codex review #11 r3 (2026-05-25) — DO emit. The earlier r8 patch
      // treated `.noAudioCaptured` symmetrically with `.captureStalled`,
      // but grep verified they are not symmetric in the kernel path:
      //   - `.captureStalled` rich path: observer.handleCaptureStall →
      //     emitter.stallFired — actively wired in the new factory stack.
      //   - `.noAudioCaptured` rich path: emitter.noAudioCaptured(ctx:) is
      //     ONLY called from the old Parakeet pipeline and
      //     `WhisperKitPipeline.swift:623` — both BYPASSED by PR-4b.4 cutover.
      //     Nothing in the kernel / observer / driver invokes it.
      // Result: skipping here would drop the no-audio Sentry signal
      // entirely. Emit the basic captureError so the timeline keeps the
      // event; the richer ctx-bearing path is a follow-up (matches the
      // §2.2 "rich diagnostic dicts deferred" non-goal).
      captureError(
        NSError(
          domain: "EnviousWispr", code: -16,
          userInfo: [NSLocalizedDescriptionKey: "No audio captured"]),
        .audioCaptureFailed, "recording",
        ["backend": backend.rawValue, "failure_mode": "no_audio_captured"])
    }
  }
}
