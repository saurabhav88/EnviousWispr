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
  let pipeline: TranscriptionPipeline
  let whisperKitPipeline: WhisperKitPipeline

  init(
    asrManager: any ASRManagerInterface,
    pipeline: TranscriptionPipeline,
    whisperKitPipeline: WhisperKitPipeline
  ) {
    self.asrManager = asrManager
    self.pipeline = pipeline
    self.whisperKitPipeline = whisperKitPipeline

    asrManager.onServiceInterrupted = { [weak self] in
      guard let self else { return }
      let pState = self.pipeline.state
      let wkState = self.whisperKitPipeline.state
      Task {
        await AppLogger.shared.log(
          "[ASREventRouter] ASR onServiceInterrupted — parakeet=\(pState), whisperKit=\(wkState)",
          level: .info, category: "XPC"
        )
      }
      if pState == .loadingModel || pState == .recording || pState == .transcribing
        || pState == .polishing
      {
        self.pipeline.handleASRServiceInterruption()
      } else if wkState == .recording || wkState == .transcribing || wkState == .polishing {
        self.whisperKitPipeline.handleASRServiceInterruption()
      }
    }
  }

}
