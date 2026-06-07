import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// PR8 of #763 — routes ASR service-interruption events to whichever
/// pipeline is currently active. Reads pipeline state directly; no
/// resolver-helper closure needed.
@MainActor
final class ASREventRouter {
  let kernelDriver: KernelDictationDriver
  let whisperKitKernelDriver: KernelDictationDriver

  init(
    asrManager: any ASRManagerInterface,
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver
  ) {
    self.kernelDriver = kernelDriver
    self.whisperKitKernelDriver = whisperKitKernelDriver

    asrManager.onServiceInterrupted = { [weak self] in
      guard let self else { return }
      let pState = self.kernelDriver.state
      let wkState = self.whisperKitKernelDriver.state
      Task {
        await AppLogger.shared.log(
          "[ASREventRouter] ASR onServiceInterrupted — parakeet=\(pState), whisperKit=\(wkState)",
          level: .info, category: "XPC"
        )
      }
      if pState == .loadingModel || pState == .recording || pState == .transcribing {
        self.kernelDriver.handleASRServiceInterruption()
      } else if wkState == .recording || wkState == .transcribing {
        self.whisperKitKernelDriver.handleASRServiceInterruption()
      } else {
        // #959: the Parakeet ASR service (this `asrManager`) was reaped while
        // idle — `onServiceInterrupted` only fires when a resident model was
        // loaded (`wasLoaded || wasStreaming`), and neither driver is active, so
        // this is the reap-while-idle case that drops readiness to `.notReady`.
        // Mark the Parakeet driver so the next press warm-respawns (re-warm ~0.2s
        // + record) instead of showing the #879 cold pill. The driver owns the
        // marker + reclaim telemetry (keeps this router's import set minimal).
        self.kernelDriver.markResidentModelLostWhileIdle()
      }
    }
  }

}
