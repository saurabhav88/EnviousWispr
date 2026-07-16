import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// #1408: assembles a `PipelineStateChangeHandler` from the AppKit-owned seams
/// its closures need, so `DictationLifecycleCoordinator` stays a thin wiring site
/// (the same move #1434 made for `DictationCompletedReporting`). Pure closure
/// assembly — no state, no decisions; the pure planner owns which effect fires.
///
/// #1567 (heartpath E3): these closures translate each typed planner effect into
/// a typed `RecordingWarningReason`; `DictationNarrator` owns every user-facing
/// sentence. No literals live here anymore.
@MainActor
enum PipelineStateChangeHandlerFactory {
  /// The coordinator-owned seams the handler's closures reach back into. Passed
  /// as closures rather than a coordinator reference so the coordinator's own
  /// methods stay `private` (its non-private-method ceiling is exactly full) and
  /// the handler cannot reach anything it was not handed.
  struct Deps {
    let showOverlay: @MainActor (OverlayIntent) -> Void
    let cancelPendingWarning: @MainActor () -> Void
    /// The generic single-slot post-completion pill. Last-writer-wins by design;
    /// the planner guarantees exactly one caller per completion. #1567: carries a
    /// typed `RecordingWarningReason`; `DictationNarrator` authors the sentence.
    let schedulePostCompletionWarning: @MainActor (RecordingWarningReason) -> Void
    let appendTranscript: @MainActor (Transcript) -> Void
    /// #1063 PR1: the durable save landed, so this session's spool + key can go.
    let onDurableSave: @MainActor (String) -> Void
    /// `nil` once the coordinator is gone, so a completion racing teardown emits
    /// nothing rather than reporting an empty input mode.
    let inputMode: @MainActor () -> String?
    /// This handler's driver — completion telemetry reads its length, stop
    /// reason, route, capture health, and salvage markers (#1060, #1376, #1434).
    let driver: KernelDictationDriver
  }

  static func make(backendLabel: String, deps: Deps) -> PipelineStateChangeHandler {
    PipelineStateChangeHandler(
      showOverlay: { intent in deps.showOverlay(intent) },
      cancelPendingWarning: { deps.cancelPendingWarning() },
      schedulePolishFailedWarning: {
        deps.schedulePostCompletionWarning(.polishFailed)
      },
      appendCompletedTranscript: { t in
        deps.appendTranscript(t)
        // #1063 PR1: the save is durable by `.complete`; delete this session's
        // spool + key. nil unless recovery was armed for this take.
        if let sid = t.recoverySessionID { deps.onDurableSave(sid) }
      },
      reportDictationCompleted: { t in
        guard let inputMode = deps.inputMode() else { return }
        // #1376/#1434: route + capture-health + salvage argument assembly lives
        // in `DictationCompletedReporting` (thin-factory discipline).
        DictationCompletedReporting.report(
          transcript: t, inputMode: inputMode, driver: deps.driver)
      },
      reportPipelineFailed: { msg in
        TelemetryService.shared.pipelineFailed(
          stage: "transcription", errorCategory: "pipeline_error", errorCode: msg,
          recoverable: false, backend: backendLabel)
      },
      // #1167: history-save-failed pill (post-completion warning slot, ~400 ms).
      scheduleHistorySaveFailedWarning: { reason in
        deps.schedulePostCompletionWarning(.historySaveFailed(reason: reason))
      },
      // #1434: salvaged-lead disclosure pill — the degraded-lead retry recovered
      // this dictation by trimming a poisoned opening, so the pasted text is
      // missing its lead.
      scheduleSalvagedLeadWarning: {
        deps.schedulePostCompletionWarning(.salvagedBeginning)
      },
      // #1408: capture died mid-recording and the pasted text is what survived.
      // Forward the two typed facts unchanged; `DictationNarrator` picks the
      // sentence family (only a VERIFIED device removal may say "Microphone
      // disconnected"; a non-disconnect salvage gets the neutral wording) and the
      // both-ends-lost variant. The four sentences are founder-LOCKED (2026-07-15).
      scheduleInterruptionWarning: { disclosure, alsoTrimmedLead in
        deps.schedulePostCompletionWarning(
          .interruptedTail(disclosure: disclosure, alsoTrimmedLead: alsoTrimmedLead))
      }
    )
  }
}
