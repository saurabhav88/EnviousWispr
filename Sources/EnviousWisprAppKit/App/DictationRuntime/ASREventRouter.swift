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
      } else if pState == .polishing || wkState == .polishing {
        // Codex PR #990 P2 (#959): a crash/reap during polishing is not an
        // idle reap (session still finalizing, see WONTFIX in
        // `KernelDictationDriver.pipelineState(for:)`) — log-only.
      } else {
        // #959: this `asrManager` (Parakeet's) service was reaped while
        // Parakeet itself is idle — mark it so the next Parakeet press
        // warm-respawns instead of showing the #879 cold pill. #1707 Codex
        // r12: fires on Parakeet's own idle state ONLY, regardless of
        // `wkState` — Parakeet's XPC crash cannot affect WhisperKit's
        // separate in-process engine. A prior version forwarded this to
        // `whisperKitKernelDriver` whenever WhisperKit was recording,
        // silently truncating a healthy dictation (WhisperKit's own
        // readiness always reports fine, so recovery falsely "succeeded").
        self.kernelDriver.markResidentModelLostWhileIdle()
      }
    }
  }

}
