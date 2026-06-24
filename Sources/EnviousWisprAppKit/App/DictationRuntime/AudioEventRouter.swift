import AVFAudio
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// PR8 of #763 — routes audio engine + route-change events to the active pipeline;
/// installs two callbacks on `audioCapture` and one
/// `AVAudioEngineConfigurationChange` observer at construction time.
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
  let captureTelemetry: CaptureTelemetryState

  let resolveActiveCaptureBackend:
    @MainActor () -> DictationLifecycleCoordinator.LastCapturingBackend?

  init(
    audioCapture: any AudioCaptureInterface,
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver,
    captureTelemetry: CaptureTelemetryState,
    resolveActiveCaptureBackend: @escaping @MainActor () -> DictationLifecycleCoordinator
      .LastCapturingBackend?
  ) {
    self.audioCapture = audioCapture
    self.kernelDriver = kernelDriver
    self.whisperKitKernelDriver = whisperKitKernelDriver
    self.captureTelemetry = captureTelemetry
    self.resolveActiveCaptureBackend = resolveActiveCaptureBackend

    NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.captureTelemetry.incrementConfigChange()
        let route = self.audioCapture.currentAudioRoute
        SentryBreadcrumb.add(
          stage: "audio", message: "Audio route changed", level: .warning,
          data: [
            "audio_route": route
          ])
        SentryBreadcrumb.updateAudioRoute(route)
      }
    }

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
  }
}
