import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// PR8 of #763 — routes capture-stall, XPC reply timeout, and capture-session
/// interruption events to the active pipeline's telemetry target. Filters
/// stale callbacks via `isCurrentSession` before dispatching.
@MainActor
final class WedgeRecoveryRouter {
  let audioCapture: any AudioCaptureInterface
  let pipeline: TranscriptionPipeline
  let whisperKitPipeline: WhisperKitPipeline

  let isCurrentSession: @MainActor (UInt64) -> Bool
  let resolveActiveTelemetryTarget: @MainActor () -> (any HeartPathTelemetryTarget)?

  init(
    audioCapture: any AudioCaptureInterface,
    pipeline: TranscriptionPipeline,
    whisperKitPipeline: WhisperKitPipeline,
    isCurrentSession: @escaping @MainActor (UInt64) -> Bool,
    resolveActiveTelemetryTarget: @escaping @MainActor () -> (any HeartPathTelemetryTarget)?
  ) {
    self.audioCapture = audioCapture
    self.pipeline = pipeline
    self.whisperKitPipeline = whisperKitPipeline
    self.isCurrentSession = isCurrentSession
    self.resolveActiveTelemetryTarget = resolveActiveTelemetryTarget

    audioCapture.onCaptureStalled = { [weak self] ctx in
      guard let self, self.isCurrentSession(ctx.sessionID) else { return }
      self.resolveActiveTelemetryTarget()?.handleCaptureStall(ctx)
    }
    audioCapture.onXPCReplyFailed = { [weak self] ctx in
      guard let self, self.isCurrentSession(ctx.sessionID) else { return }
      self.resolveActiveTelemetryTarget()?.handleXPCReplyFailed(ctx)
    }
    audioCapture.onCaptureSessionInterruption = { [weak self] ctx in
      guard let self, self.isCurrentSession(ctx.sessionID) else { return }
      self.resolveActiveTelemetryTarget()?.handleCaptureSessionInterruption(ctx)
    }
  }

}
