import EnviousWisprCore
import Foundation

/// Executes the side-effect plan produced by `PipelineStateChangePlanner`.
///
/// One instance per pipeline (Parakeet / WhisperKit). The handler holds no
/// pipeline reference itself — the caller passes the pipeline-scoped inputs
/// (`pipelineOverlayIntent`, `lastPolishError`, `currentTranscript`) for each
/// transition. the former root state remains the owner of cross-pipeline state (the
/// `postCompletionWarningTask`, the tiebreaker, the hotkey register/unregister
/// ordering), and the handler reaches back into those through narrow
/// callbacks.
///
/// Why the warning task is NOT owned by the handler: the current production
/// `schedulePostCompletionWarning` at the former root-state file treats
/// the WhisperKit driver's state at `.complete` (pre-Rung-5 also `.ready`)
/// delayed guard. That check crosses pipeline boundaries (the warning can be
/// scheduled from Parakeet's closure and still fire if WhisperKit is in
/// `.ready` when the 400 ms sleep wakes). Moving the task into a per-pipeline
/// handler would split that shared lifecycle across two owners — a behavior
/// change, not a refactor. Preserved verbatim via the `cancelPendingWarning`
/// and `schedulePolishFailedWarning` callbacks.
@MainActor
public final class PipelineStateChangeHandler {
  /// Overlay show is now a closure rather than a protocol existential. The
  /// caller wires this directly to the concrete `RecordingOverlayPanel.show(
  /// intent:audioLevelProvider:isRecordingLocked:)` so dispatch is static,
  /// matching commit-1's inline behavior exactly.
  public typealias ShowOverlay = @MainActor (OverlayIntent) -> Void

  private let showOverlay: ShowOverlay
  private let cancelPendingWarning: @MainActor () -> Void
  private let schedulePolishFailedWarning: @MainActor () -> Void
  private let appendCompletedTranscript: @MainActor (Transcript) -> Void
  private let reportDictationCompleted: @MainActor (Transcript) -> Void
  private let reportPipelineFailed: @MainActor (String) -> Void
  /// #1167: schedule the transient "Couldn't save to history: <reason>" pill.
  private let scheduleHistorySaveFailedWarning: @MainActor (String) -> Void
  /// #1434: schedule the transient salvaged-lead disclosure pill.
  private let scheduleSalvagedLeadWarning: @MainActor () -> Void
  /// #1408: schedule the transient interruption disclosure pill. The disclosure
  /// picks the sentence family (mic-disconnect vs neutral) and the flag picks
  /// between the tail-only and both-ends-lost copies; the caller owns all four
  /// literals (the message is wired at the factory site, never in here).
  private let scheduleInterruptionWarning:
    @MainActor (_ disclosure: CompletionInterruptionDisclosure, _ alsoTrimmedLead: Bool) -> Void

  public init(
    showOverlay: @escaping ShowOverlay,
    cancelPendingWarning: @escaping @MainActor () -> Void,
    schedulePolishFailedWarning: @escaping @MainActor () -> Void,
    appendCompletedTranscript: @escaping @MainActor (Transcript) -> Void,
    reportDictationCompleted: @escaping @MainActor (Transcript) -> Void,
    reportPipelineFailed: @escaping @MainActor (String) -> Void,
    scheduleHistorySaveFailedWarning: @escaping @MainActor (String) -> Void,
    scheduleSalvagedLeadWarning: @escaping @MainActor () -> Void = {},
    scheduleInterruptionWarning: @escaping @MainActor (
      _ disclosure: CompletionInterruptionDisclosure, _ alsoTrimmedLead: Bool
    ) -> Void = { _, _ in }
  ) {
    self.showOverlay = showOverlay
    self.cancelPendingWarning = cancelPendingWarning
    self.schedulePolishFailedWarning = schedulePolishFailedWarning
    self.appendCompletedTranscript = appendCompletedTranscript
    self.reportDictationCompleted = reportDictationCompleted
    self.reportPipelineFailed = reportPipelineFailed
    self.scheduleHistorySaveFailedWarning = scheduleHistorySaveFailedWarning
    self.scheduleSalvagedLeadWarning = scheduleSalvagedLeadWarning
    self.scheduleInterruptionWarning = scheduleInterruptionWarning
  }

  /// Drive the full state-change behavior contract for one pipeline.
  ///
  /// Step 1 — delegate plan derivation to the pure planner (tested
  /// comprehensively in `PipelineStateChangePlannerTests`).
  /// Step 2 — execute each side effect through the injected dependencies.
  /// No decision logic beyond translating typed effects into calls.
  public func handle(
    to newState: any PipelineStateProtocol,
    pipelineOverlayIntent: OverlayIntent,
    lastPolishError: String?,
    currentTranscript: Transcript?,
    historySaved: Bool,
    historySaveReason: String?,
    salvagedLead: Bool = false,
    interruptionDisclosure: CompletionInterruptionDisclosure? = nil
  ) {
    let plan = PipelineStateChangePlanner.plan(
      to: newState,
      pipelineOverlayIntent: pipelineOverlayIntent,
      isClipboardFallback: currentTranscript?.metrics?.pasteTier == "clipboard_only"
        || currentTranscript?.metrics?.pasteTier == "clipboard_only_ax_denied",
      isAccessibilityToast: currentTranscript?.metrics?.pasteTier == "clipboard_only_ax_denied",
      lastPolishError: lastPolishError,
      hasCurrentTranscript: currentTranscript != nil,
      historySaved: historySaved,
      historySaveReason: historySaveReason,
      salvagedLead: salvagedLead,
      interruptionDisclosure: interruptionDisclosure
    )
    for effect in plan.effects {
      switch effect {
      case .cancelPendingWarning:
        cancelPendingWarning()
      case .schedulePolishFailedWarning:
        schedulePolishFailedWarning()
      case .showOverlay(let intent):
        showOverlay(intent)
      case .appendCompletedTranscript:
        if let t = currentTranscript {
          appendCompletedTranscript(t)
        }
      case .reportDictationCompleted:
        if let t = currentTranscript {
          reportDictationCompleted(t)
        }
      case .reportPipelineFailed(let msg):
        reportPipelineFailed(msg)
      case .scheduleHistorySaveFailedWarning(let reason):
        scheduleHistorySaveFailedWarning(reason)
      case .scheduleSalvagedLeadWarning:
        scheduleSalvagedLeadWarning()
      case .scheduleInterruptionWarning(let disclosure, let alsoTrimmedLead):
        scheduleInterruptionWarning(disclosure, alsoTrimmedLead)
      }
    }
  }
}
