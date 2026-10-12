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
    // #3546 §3.7 T1: the take and model recorded for THIS row when it was written, so a
    // late report cannot borrow a newer take's. Absent for a row the kernel did not record.
    let concluded = driver.concludedTake(forTranscriptID: transcript.id)
    TelemetryService.shared.reportDictationCompleted(
      transcript: transcript, inputMode: inputMode,
      model: concluded?.model,
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
      // #1714: WHY this session's microphone was chosen, frozen by the kernel
      // after the final engine-start attempt.
      inputResolutionSource: driver.lastInputResolutionSource,
      // #1434: capture-health facts + salvage marker. Counters/flags ride
      // only when non-zero/true (omit-when-zero keeps the event lean).
      captureNativeRateHz: health?.nativeRateHz,
      captureRingDropCount: positive(health?.ringDropCount),
      captureConverterErrorCount: positive(health?.converterErrorCount),
      captureZeroOutputCount: positive(health?.zeroOutputCount),
      captureRateDivergenceDetected: whenTrue(health?.rateDivergenceDetected),
      captureFormatStabilized: health?.formatStabilized,
      captureRebuiltForFormat: whenTrue(health?.captureRebuiltForFormat),
      // #1523: bound device's native channel count (nil omits; 0 emits as an
      // anomaly). Not gated on positivity — 1 and 2 are both meaningful.
      captureNativeChannelCount: health?.nativeChannelCount,
      // #2664: which input channel the capture took; same optionality (nil omits,
      // 0 is the measured default and travels).
      captureInputChannel: health?.inputChannel,
      salvagedLeadTrimMs: driver.lastSalvagedLeadTrimMs,
      // #1408: which interruption cut this dictation short. `stop_reason` already
      // says one did; this names it. Absent on an uninterrupted completion.
      interruptedBy: driver.lastAudioInterruptionCause?.rawValue,
      // #1707: which ASR/XPC-helper salvage outcome preceded this completion.
      // Absent unless a live ASR crash was salvaged during this session.
      asrSalvageOutcome: driver.lastASRSalvageOutcome?.rawValue,
      // #1707 Phase 2: without this, a retry-rescued dictation's completion
      // is invisible — it never reaches either Sentry capture site (those
      // only fire on `.asrFailed`/`.asrInterrupted`), so this read-through
      // chain is a successful retry's ONLY visibility.
      asrRetryOutcome: driver.asrRetryOutcome?.rawValue,
      // #1846: the take this completion belongs to, never a live read of the in-flight
      // take key — if the user started talking again before this report was filed, a live
      // read would stamp this event with the NEXT take's id, which is worse than absent
      // because it joins cleanly to the wrong dictation.
      // #3546: read from the row's own record, written with the row by the kernel's one
      // store path. An evicted or unknown row omits the key rather than fall back to the
      // latest take (`lastTakeID`), which can be a newer one.
      takeID: concluded?.takeID,
      // #3195: content-free; nil unless this take's live Apple polish completed.
      afmPrewarm: driver.lastAFMPrewarm)
  }

  private static func positive(_ value: Int?) -> Int? {
    value.flatMap { $0 > 0 ? $0 : nil }
  }

  private static func whenTrue(_ value: Bool?) -> Bool? {
    value.flatMap { $0 ? true : nil }
  }
}
