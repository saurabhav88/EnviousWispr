import EnviousWisprCore
import EnviousWisprLLM
import Foundation

/// Every side effect the state-change closure produces, as a value.
///
/// Executed in order by the caller. The caller owns stateful concerns
/// (the warning `Task`, the concrete telemetry service, the overlay panel);
/// the planner is a pure projection from inputs to this list.
enum PipelineStateSideEffect: Equatable, Sendable {
  /// Cancel any pending post-completion warning task. Emitted on every
  /// non-complete transition — mirrors the former root-state file behavior.
  case cancelPendingWarning

  /// Schedule the "Polish failed -- using raw text" warning 400 ms after
  /// completion. Emitted ONLY on `.complete` when a polish error was recorded
  /// AND the paste did not fall back to clipboard-only.
  case schedulePolishFailedWarning

  /// Render this intent on the overlay. Always emitted exactly once per call.
  case showOverlay(OverlayIntent)

  /// Append the just-completed transcript to the in-memory history cache
  /// (no disk I/O — finalizer already persisted before `.complete` fires).
  /// Emitted only when `hasCurrentTranscript` is true; `.complete` with
  /// `nil` transcript is treated as a transient stale-cache condition and
  /// no append is emitted.
  case appendCompletedTranscript

  /// Call `TelemetryService.shared.reportDictationCompleted(transcript:inputMode:)`
  /// using the caller's current transcript. Emitted only when `.complete` AND
  /// the pipeline has a current transcript — matches the former root state's `if let t`.
  case reportDictationCompleted

  /// Call `TelemetryService.shared.pipelineFailed(...)` with the captured error
  /// code. The caller supplies the fixed `stage` / `errorCategory` / `backend`
  /// literals that today live in the former root state's closures.
  case reportPipelineFailed(errorCode: String)

  /// #1167: schedule the transient "Couldn't save to history: <reason>" pill
  /// ~400 ms after completion, concurrent with the (already-completed) paste.
  /// Emitted ONLY on `.complete` when the durable history save threw but
  /// delivery still ran (best-effort save). Reuses the single post-completion
  /// warning slot, so it is mutually exclusive with `schedulePolishFailedWarning`.
  case scheduleHistorySaveFailedWarning(reason: String)
}

struct PipelineStateChangePlan: Equatable, Sendable {
  let effects: [PipelineStateSideEffect]
}

/// Pure projection from a state transition's observable inputs to the ordered
/// list of side effects the former root state's `onStateChange` closures must perform.
///
/// **What lives here:**
/// - Three-way overlay priority on `.complete`
///   (clipboardFallback > polish-failed-warning > success).
/// - Warning-task cancellation on any non-complete transition.
/// - Telemetry + history-reload emission for `.complete` / `.error`.
///
/// **What does NOT live here** (stays with the caller / future handler):
/// - Stateful `Task` ownership for the delayed polish-failed warning.
/// - The `.ready`-as-completion-equivalent guard inside the delayed warning
///   closure (that guard fires at 400 ms, not at plan time).
/// - Hotkey register/unregister, `isRecordingLocked = false` reset, the
///   inactive→active tiebreaker, the `onPipelineStateChange?` fan-out.
///   All four are root-state-only concerns that the bible (§7) keeps inline.
///
/// Kept `internal` to `EnviousWisprPipeline`: only the handler in this
/// module calls `plan(...)`; tests reach it through `@testable import`.
@MainActor
enum PipelineStateChangePlanner {
  static func plan(
    to newState: any PipelineStateProtocol,
    pipelineOverlayIntent: OverlayIntent,
    isClipboardFallback: Bool,
    isAccessibilityToast: Bool,
    lastPolishError: String?,
    hasCurrentTranscript: Bool,
    historySaved: Bool,
    historySaveReason: String?
  ) -> PipelineStateChangePlan {
    var effects: [PipelineStateSideEffect] = []

    // #1167: a degraded-save completion (delivery ran, history write threw).
    // Only meaningful on `.complete` with a transcript in hand.
    let historySaveFailed = hasCurrentTranscript && !historySaved

    // Step 1 — overlay resolution + warning scheduling / cancellation.
    // Order mirrors the production closures at the former root-state file: resolve intent, schedule warning iff applicable, then show.
    let resolvedOverlayIntent: OverlayIntent
    switch newState.activity {
    case .complete:
      if isAccessibilityToast {
        resolvedOverlayIntent = .accessibilityToast
      } else if isClipboardFallback {
        resolvedOverlayIntent = .clipboardFallback
      } else if let polishError = lastPolishError {
        resolvedOverlayIntent = pipelineOverlayIntent
        // #945: a "skipped" notice (no key yet, too long, timed out) is not a
        // hard failure — the in-window banner shows the actionable
        // "AI cleanup skipped: ..." message, but the transient
        // "Polish failed -- using raw text" overlay would contradict it, so
        // suppress it for skips. Real failures (and the unchanged Apple
        // Intelligence / legacy strings) still schedule the warning.
        // #1167: a history-save failure takes the single post-completion
        // warning slot (its pill is scheduled in Step 2), so suppress the
        // polish-failed pill when both fired this session.
        if !historySaveFailed, !PolishFailureReason.isSkipNotice(polishError) {
          effects.append(.schedulePolishFailedWarning)
        }
      } else {
        resolvedOverlayIntent = pipelineOverlayIntent
      }
    default:
      effects.append(.cancelPendingWarning)
      resolvedOverlayIntent = pipelineOverlayIntent
    }
    effects.append(.showOverlay(resolvedOverlayIntent))

    // Step 2 — complete-path: append to in-memory history + telemetry.
    // Phase C: replaced unconditional disk-backed reload with an
    // in-memory append that only fires when the pipeline has a
    // current transcript. Finalizer already persisted by the time
    // `.complete` is observed (TranscriptFinalizer.swift:126), so the
    // new row is on disk regardless. The in-memory append keeps the
    // history cache visibly fresh without an O(n) disk scan.
    if case .complete = newState.activity {
      if hasCurrentTranscript {
        // #1167: skip the in-memory history append on a save failure — the row
        // was never persisted, so the append would show a phantom entry that
        // vanishes on restart (it reappears as a "Recovered" entry via the
        // retained crash-recovery spool). Skipping the append also skips the
        // `onDurableSave` spool cleanup wired inside that handler, so the spool
        // is retained. Instead, schedule the reason pill. Telemetry still fires.
        if historySaved {
          effects.append(.appendCompletedTranscript)
        } else if let reason = historySaveReason {
          effects.append(.scheduleHistorySaveFailedWarning(reason: reason))
        }
        effects.append(.reportDictationCompleted)
      }
    }

    // Step 3 — error-path telemetry.
    if case .error(let msg) = newState.activity {
      effects.append(.reportPipelineFailed(errorCode: msg))
    }

    return PipelineStateChangePlan(effects: effects)
  }
}
