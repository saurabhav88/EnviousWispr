import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// #1408: assembles a `PipelineStateChangeHandler` from the AppKit-owned seams
/// its closures need, so `DictationLifecycleCoordinator` stays a thin wiring site
/// (the same move #1434 made for `DictationCompletedReporting`). Pure closure
/// assembly — no state, no decisions; the pure planner owns which effect fires
/// and this file owns what each one says.
///
/// **The post-completion notice literals live HERE, one per site.** They are
/// wired at the factory rather than hardcoded inside the shared
/// `schedulePostCompletionWarning` mechanism, so the single warning slot stays a
/// generic mechanism and each caller owns its own words. No em-dashes: this copy
/// is user-facing.
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
    /// the planner guarantees exactly one caller per completion.
    let schedulePostCompletionWarning: @MainActor (String) -> Void
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
        deps.schedulePostCompletionWarning("Polish failed -- using raw text")
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
        deps.schedulePostCompletionWarning("Couldn't save to history: \(reason)")
      },
      // #1434: salvaged-lead disclosure pill — the degraded-lead retry recovered
      // this dictation by trimming a poisoned opening, so the pasted text is
      // missing its lead.
      scheduleSalvagedLeadWarning: {
        deps.schedulePostCompletionWarning("Beginning of dictation was unclear and was skipped")
      },
      // #1408: capture died mid-recording and the pasted text is what survived.
      // The disclosure picks the sentence family: only a VERIFIED device removal
      // may say "Microphone disconnected"; every other interruption gets the
      // neutral "Recording interrupted" (grounded review A1 — a non-disconnect
      // salvage must not paste truncated text silently). When the lead was ALSO
      // trimmed this take lost both ends, so the copy stops claiming the loss is
      // only at the end. All four strings fit the pill's single line (~49
      // characters before it truncates). The microphone pair is founder-approved
      // (2026-07-09); the neutral pair is provisional pending founder sign-off
      // (plan §21.3) and must not ship in a release before that lands.
      scheduleInterruptionWarning: { disclosure, alsoTrimmedLead in
        let message: String
        switch disclosure {
        case .deviceRemoved:
          message =
            alsoTrimmedLead
            ? "Microphone disconnected. Words may be missing."
            : "Microphone disconnected. Text may be cut short."
        case .otherInterruption:
          message =
            alsoTrimmedLead
            ? "Recording interrupted. Words may be missing."
            : "Recording interrupted. Text may be cut short."
        }
        deps.schedulePostCompletionWarning(message)
      }
    )
  }
}
