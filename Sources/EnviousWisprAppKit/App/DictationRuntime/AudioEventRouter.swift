import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// PR8 of #763 — routes audio engine + route-change events to the active pipeline;
/// installs the interruption/error/VAD callbacks on `audioCapture` at
/// construction time.
///
/// Lifetime: held by `DictationRuntime`, which is `@State` on
/// `EnviousWisprApp`, so the router lives for the app's lifetime. No `deinit`
/// cleanup: same shape as the prior the former root state code, where these observer
/// blocks and callback slots persisted for the full app lifetime. Tests use
/// fresh spy mocks, so test-side cleanup is not required either.
@MainActor
final class AudioEventRouter {
  let audioCapture: any AudioCaptureInterface
  let kernelDriver: KernelDictationDriver
  let whisperKitKernelDriver: KernelDictationDriver
  let recordingOverlay: RecordingOverlayPanel

  let resolveActiveCaptureBackend:
    @MainActor () -> DictationLifecycleCoordinator.LastCapturingBackend?

  init(
    audioCapture: any AudioCaptureInterface,
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver,
    recordingOverlay: RecordingOverlayPanel,
    resolveActiveCaptureBackend: @escaping @MainActor () -> DictationLifecycleCoordinator
      .LastCapturingBackend?
  ) {
    self.audioCapture = audioCapture
    self.kernelDriver = kernelDriver
    self.whisperKitKernelDriver = whisperKitKernelDriver
    self.recordingOverlay = recordingOverlay
    self.resolveActiveCaptureBackend = resolveActiveCaptureBackend

    audioCapture.onEngineInterrupted = { [weak self] cause in
      guard let self else { return }
      let pState = self.kernelDriver.state
      let wkState = self.whisperKitKernelDriver.state
      Task {
        await AppLogger.shared.log(
          "[AudioEventRouter] Audio onEngineInterrupted — parakeet=\(pState), whisperKit=\(wkState)",
          level: .info, category: "XPC"
        )
      }
      SentryBreadcrumb.add(
        stage: "audio", message: "Audio XPC interrupted", level: .error,
        data: [
          "parakeet_state": "\(pState)",
          "whisperkit_state": "\(wkState)",
        ])
      switch self.resolveActiveCaptureBackend() {
      case .parakeet:
        self.kernelDriver.handleEngineInterruption(cause)
      case .whisperKit:
        self.whisperKitKernelDriver.handleEngineInterruption(cause)
      case nil:
        break
      }
    }

    audioCapture.onXPCServiceError = { [weak self] ctx in
      guard let self else { return }
      let handlerKind: XPCHandlerKind = {
        switch ctx.kind {
        case .interruptCapturing: return .interrupt
        case .invalidateCapturing, .invalidateIdle: return .invalidate
        }
      }()
      let wasCapturing = ctx.kind != .invalidateIdle
      let recordingDurationMs: Any =
        ctx.recordingDurationNs.map { Int($0 / 1_000_000) } ?? NSNull()
      let extras: [String: Any] = [
        "xpc.handler": handlerKind.rawValue,
        "xpc.was_capturing": wasCapturing,
        "xpc.kind": ctx.kind.rawValue,
        "capture_session_id": ctx.sessionID.map { Int($0) } ?? NSNull(),
        "capture.route": self.audioCapture.currentAudioRoute,
        "audio.recording_duration_ms": recordingDurationMs,
      ]
      SentryBreadcrumb.captureError(
        HeartPathError.audioXPCInterrupted(
          handler: handlerKind, wasCapturing: wasCapturing),
        category: .xpcServiceError,
        stage: "audio",
        extra: extras
      )
    }

    // #1194: forward resolved start-op retries to PostHog. Diagnostic-only —
    // the proxy already wrote the app.log line; this is the fleet-level signal.
    audioCapture.onAudioStartRetryResolved = { ctx in
      TelemetryService.shared.audioStartRetryResolved(
        stage: ctx.stage,
        trigger: ctx.trigger,
        outcome: ctx.outcome,
        recoveryMs: ctx.recoveryMs
      )
    }

    // Kernel-owned path: leave a preinstalled single-slot owner intact.
    // If unclaimed, install the legacy App-router fallback.
    if audioCapture.onVADAutoStop == nil {
      audioCapture.onVADAutoStop = { [weak self] in
        guard let self else { return }
        if self.kernelDriver.state == .recording {
          Task { await self.kernelDriver.stopAndTranscribe() }
        } else if self.whisperKitKernelDriver.state == .recording {
          Task { await self.whisperKitKernelDriver.stopAndTranscribe() }
        }
      }
    }

    // #1224: the service already decided eligibility (broken + auto-stop-on +
    // not-yet-shown) before firing this — no re-check needed here, just show
    // the honest, low-weight notice via the existing in-panel mechanism.
    // `flashRecordingNotice` no-ops if no recording panel is showing.
    audioCapture.onVADModelUnavailable = { [weak self] in
      self?.recordingOverlay.flashRecordingNotice(
        "Auto-stop on silence is unavailable right now", dismissAfter: 4.0)
    }
  }
}
