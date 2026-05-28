import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// PR8 of #763 — routes ASR service-interruption events to whichever
/// pipeline is currently active. Reads pipeline state directly; no
/// resolver-helper closure needed.
@MainActor
final class ASREventRouter {
  let asrManager: any ASRManagerInterface
  let kernelDriver: KernelDictationDriver
  let whisperKitKernelDriver: KernelDictationDriver

  init(
    asrManager: any ASRManagerInterface,
    kernelDriver: KernelDictationDriver,
    whisperKitKernelDriver: KernelDictationDriver
  ) {
    self.asrManager = asrManager
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
      }
    }
  }

}
