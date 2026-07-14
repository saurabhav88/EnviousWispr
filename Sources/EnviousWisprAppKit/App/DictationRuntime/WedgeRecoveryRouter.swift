import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// PR8 of #763 — routes capture-stall events to the active pipeline's telemetry
/// target. Filters stale callbacks via `isCurrentSession` before dispatching.
@MainActor
final class WedgeRecoveryRouter {
  let isCurrentSession: @MainActor (UInt64) -> Bool
  let resolveActiveTelemetryTarget: @MainActor () -> (any HeartPathTelemetryTarget)?

  init(
    audioCapture: any AudioCaptureInterface,
    kernelDriver _: KernelDictationDriver,
    whisperKitKernelDriver _: KernelDictationDriver,
    isCurrentSession: @escaping @MainActor (UInt64) -> Bool,
    resolveActiveTelemetryTarget: @escaping @MainActor () -> (any HeartPathTelemetryTarget)?
  ) {
    self.isCurrentSession = isCurrentSession
    self.resolveActiveTelemetryTarget = resolveActiveTelemetryTarget

    audioCapture.onCaptureStalled = { [weak self] ctx in
      guard let self, self.isCurrentSession(ctx.sessionID) else { return }
      self.resolveActiveTelemetryTarget()?.handleCaptureStall(ctx)
    }
  }

}
