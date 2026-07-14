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

  let resolveActiveCaptureBackend:
    @MainActor () -> DictationLifecycleCoordinator.LastCapturingBackend?

  init(
    audioCapture: any AudioCaptureInterface,
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver,
    resolveActiveCaptureBackend: @escaping @MainActor () -> DictationLifecycleCoordinator
      .LastCapturingBackend?
  ) {
    self.audioCapture = audioCapture
    self.kernelDriver = kernelDriver
    self.whisperKitKernelDriver = whisperKitKernelDriver
    self.resolveActiveCaptureBackend = resolveActiveCaptureBackend

    audioCapture.onEngineInterrupted = { [weak self] cause in
      guard let self else { return }
      let pState = self.kernelDriver.state
      let wkState = self.whisperKitKernelDriver.state
      Task {
        await AppLogger.shared.log(
          "[AudioEventRouter] Audio onEngineInterrupted — parakeet=\(pState), whisperKit=\(wkState)",
          level: .info, category: "Audio"
        )
      }
      SentryBreadcrumb.add(
        stage: "audio", message: "Audio engine interrupted", level: .error,
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

    // #1224 (#1543): the "auto-stop unavailable" notice is now bound directly
    // on the shared `CaptureVADSignalSource` in `WisprBootstrapper` (the VAD
    // source reports a typed readiness fact; the App shell authors the copy),
    // so the former capture-callback arm for that notice is gone.
  }
}
