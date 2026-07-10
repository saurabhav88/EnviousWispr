import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// #1434: assembles the `dictation.completed` report from a driver's
/// post-completion pass-throughs (route, capture health, salvage marker) so
/// `DictationLifecycleCoordinator`'s state-handler factory stays a thin wiring
/// site. Pure argument mapping — no state, no decisions beyond the
/// omit-when-zero convention for counters/flags.
@MainActor
enum DictationCompletedReporting {
  static func report(
    transcript: Transcript,
    inputMode: String,
    driver: KernelDictationDriver
  ) {
    let route = driver.lastResolvedRoute
    let health = driver.lastCaptureHealth
    TelemetryService.shared.reportDictationCompleted(
      transcript: transcript, inputMode: inputMode,
      recordingSeconds: driver.lastRecordingDurationSeconds,
      stopReason: driver.lastStopReason,
      historySaveStatus: driver.lastHistorySaved ? "succeeded" : "failed",  // #1167
      historySaveErrorClass: driver.lastHistorySaveErrorClass,
      // #1376: effective-device telemetry — which mic was selected vs used.
      selectedTransport: route?.selected,
      effectiveTransport: route?.effective,
      routeReason: route?.routeReason,
      routeFallbackReason: route?.routeFallbackReason,
      inputSelectionMode: route?.inputSelectionMode,
      outputTransport: route?.outputTransport,
      routeResolutionSource: route?.routeResolutionSource,
      // #1434: capture-health facts + salvage marker. Counters/flags ride
      // only when non-zero/true (omit-when-zero keeps the event lean).
      captureNativeRateHz: health?.nativeRateHz,
      captureRingDropCount: positive(health?.ringDropCount),
      captureConverterErrorCount: positive(health?.converterErrorCount),
      captureZeroOutputCount: positive(health?.zeroOutputCount),
      captureRateDivergenceDetected: whenTrue(health?.rateDivergenceDetected),
      captureFormatStabilized: health?.formatStabilized,
      captureRebuiltForFormat: whenTrue(health?.captureRebuiltForFormat),
      salvagedLeadTrimMs: driver.lastSalvagedLeadTrimMs,
      // #1408: which interruption cut this dictation short. `stop_reason` already
      // says one did; this names it. Absent on an uninterrupted completion.
      interruptedBy: driver.lastAudioInterruptionCause?.rawValue)
  }

  private static func positive(_ value: Int?) -> Int? {
    value.flatMap { $0 > 0 ? $0 : nil }
  }

  private static func whenTrue(_ value: Bool?) -> Bool? {
    value.flatMap { $0 ? true : nil }
  }
}
