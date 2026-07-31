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

    // #1578: the same stale-session funnel, but delivery-aware. The stall
    // callback above returns `Void`, so a stale drop or an unresolved target
    // is invisible to the producer and the observation is simply lost. This
    // one answers: `true` only once the target's method has actually been
    // called, so a `false` tells the capture manager to keep the context for a
    // terminal drain instead of discarding it.
    audioCapture.onZeroSignalRefused = { [weak self] context in
      guard let self, self.isCurrentSession(context.sessionID) else { return false }
      guard let target = self.resolveActiveTelemetryTarget() else { return false }
      target.handleZeroSignalRefusal(context)
      return true
    }
  }

}
