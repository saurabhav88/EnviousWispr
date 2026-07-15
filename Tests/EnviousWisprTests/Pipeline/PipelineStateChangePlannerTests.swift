import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Characterization tests pinning the current behavior of the state-change
/// closures at the former root-state file (Parakeet) and `:409-463` (WhisperKit).
///
/// The planner is a pure projection — tests drive each state case with every
/// clipboardFallback / polishError / hasTranscript combination that the
/// production closures exercise, and pin the resulting effect list.
///
/// Before commit 2 (handler extraction) these tests fail on any behavior
/// change. After commit 2 these same tests remain the source of truth for
/// the handler's plan-level contract.
@MainActor
@Suite("PipelineStateChangePlanner — characterization")
struct PipelineStateChangePlannerTests {

  // MARK: - Shared fixtures

  private static let recordingIntent: OverlayIntent = .recording(audioLevel: 0)
  private static let hiddenIntent: OverlayIntent = .hidden
  private static let polishingIntent: OverlayIntent = .processing(label: "Polishing...")
  private static let transcribingIntent: OverlayIntent = .processing(label: "Transcribing...")

  // MARK: - Three-way .complete overlay priority

  @Test("complete + clipboard_only fallback -> .clipboardFallback wins, no warning scheduled")
  func completeClipboardFallbackWinsOverPolishWarning() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: true,
      isAccessibilityToast: false,
      lastPolishError: "polish failed for some reason",
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(plan.effects.contains(.showOverlay(.clipboardFallback)))
    #expect(!plan.effects.contains(.schedulePolishFailedWarning))
    // Clipboard fallback still reports telemetry + reloads history.
    #expect(plan.effects.contains(.appendCompletedTranscript))
    #expect(plan.effects.contains(.reportDictationCompleted))
    #expect(!plan.effects.contains(.cancelPendingWarning))
  }

  @Test("complete + accessibility toast + clipboard fallback -> accessibilityToast wins")
  func completeAccessibilityToastWinsOverClipboardFallback() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: true,
      isAccessibilityToast: true,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(plan.effects.contains(.showOverlay(.accessibilityToast)))
    #expect(!plan.effects.contains(.showOverlay(.clipboardFallback)))
  }

  @Test("complete + clipboard fallback without accessibility toast -> clipboardFallback")
  func completeClipboardFallbackWithoutAccessibilityToast() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: true,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(plan.effects.contains(.showOverlay(.clipboardFallback)))
    #expect(!plan.effects.contains(.showOverlay(.accessibilityToast)))
  }

  @Test("complete + accessibility toast without clipboard fallback -> accessibilityToast")
  func completeAccessibilityToastStandalone() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: true,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(plan.effects.contains(.showOverlay(.accessibilityToast)))
    #expect(!plan.effects.contains(.showOverlay(.clipboardFallback)))
  }

  @Test("non-complete + accessibility toast input does not emit accessibilityToast")
  func nonCompleteAccessibilityToastInputDoesNotEmitToast() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.recording,
      pipelineOverlayIntent: Self.recordingIntent,
      isClipboardFallback: true,
      isAccessibilityToast: true,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(!plan.effects.contains(.showOverlay(.accessibilityToast)))
    #expect(plan.effects.contains(.showOverlay(Self.recordingIntent)))
  }

  @Test("complete + polish failed (not clipboard) -> overlay + schedulePolishFailedWarning")
  func completePolishFailedSchedulesWarning() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: "openai 429 rate-limited",
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(plan.effects.contains(.showOverlay(.hidden)))
    #expect(plan.effects.contains(.schedulePolishFailedWarning))
    #expect(plan.effects.contains(.appendCompletedTranscript))
    #expect(plan.effects.contains(.reportDictationCompleted))
    #expect(!plan.effects.contains(.cancelPendingWarning))
  }

  @Test(
    "complete + SKIPPED polish notice -> overlay shows but NO failure warning (#945)",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/945",
      "the transient 'Polish failed' overlay must not contradict an 'AI cleanup skipped:' banner"
    )
  )
  func completeSkippedPolishSuppressesWarning() {
    // A real skip reason's composed notice ("AI cleanup skipped: no OpenAI API
    // key set yet. ...") must NOT schedule the hard-failure overlay.
    let skipNotice = PolishFailureReason.apiKeyMissing.composedMessage(provider: .openAI)
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: skipNotice,
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(plan.effects.contains(.showOverlay(.hidden)))
    #expect(!plan.effects.contains(.schedulePolishFailedWarning))
    // Still a completed dictation: telemetry + history append are unaffected.
    #expect(plan.effects.contains(.appendCompletedTranscript))
    #expect(plan.effects.contains(.reportDictationCompleted))
  }

  @Test("complete + real (failed) polish notice -> failure warning still fires (#945)")
  func completeFailedPolishStillSchedulesWarning() {
    // A real hard-failure reason's composed notice ("AI polish failed: your
    // OpenAI account is out of credits. ...") must still schedule the overlay —
    // the skip detector must not over-match the "AI polish failed:" lead-in.
    let failNotice = PolishFailureReason.outOfCredits.composedMessage(provider: .openAI)
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: failNotice,
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(plan.effects.contains(.schedulePolishFailedWarning))
  }

  @Test("complete + success (no fallback, no polish error) -> no warning, telemetry fires")
  func completeSuccessEmitsNoWarning() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(plan.effects.contains(.showOverlay(.hidden)))
    #expect(!plan.effects.contains(.schedulePolishFailedWarning))
    #expect(plan.effects.contains(.appendCompletedTranscript))
    #expect(plan.effects.contains(.reportDictationCompleted))
    #expect(!plan.effects.contains(.cancelPendingWarning))
  }

  @Test("complete without current transcript -> neither append nor telemetry fires (Phase C)")
  func completeWithoutTranscriptSkipsBothAppendAndTelemetry() {
    // Phase C (#428) contract change: when `.complete` arrives with no
    // currentTranscript, the planner emits neither `.appendCompletedTranscript`
    // nor `.reportDictationCompleted`. This is an accepted transient
    // stale-cache condition — finalizer already persisted, so the row is on
    // disk; the in-memory cache is stale until next `load()`. Previously
    // (Phase A) an unconditional disk reload fired even without a transcript.
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: false,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(!plan.effects.contains(.appendCompletedTranscript))
    #expect(!plan.effects.contains(.reportDictationCompleted))
  }

  // MARK: - Warning cancellation on non-complete transitions

  @Test("non-complete transitions cancel pending warning")
  func nonCompleteTransitionsCancelWarning() {
    let nonCompleteStates: [PipelineState] = [
      .idle, .loadingModel, .recording, .transcribing, .polishing, .error(.modelWedged),
    ]
    for state in nonCompleteStates {
      let plan = PipelineStateChangePlanner.plan(
        to: state,
        pipelineOverlayIntent: Self.recordingIntent,
        isClipboardFallback: false,
        isAccessibilityToast: false,
        lastPolishError: nil,
        hasCurrentTranscript: false,
        historySaved: true,
        historySaveReason: nil
      )
      #expect(
        plan.effects.first == .cancelPendingWarning,
        "Expected cancelPendingWarning first for state \(state); got \(plan.effects)"
      )
      #expect(
        !plan.effects.contains(.schedulePolishFailedWarning),
        "Non-complete state \(state) must not schedule warning; got \(plan.effects)"
      )
    }
  }

  // PR-5 Rung 5 (#827) deleted: the bespoke WhisperKit `.ready` case is gone.
  // The kernel driver's state mapping projects WhisperKit's pre-Rung-5 `.ready`
  // onto `PipelineState.idle`; the equivalent assertion is now the .idle row
  // in `parakeetActivityMapping`.

  // MARK: - Overlay intent pass-through (no label flattening)

  @Test("pipeline overlay intent passes through verbatim for non-complete states")
  func pipelineOverlayIntentPassesThroughVerbatim() {
    let pairs: [(PipelineState, OverlayIntent)] = [
      (.loadingModel, .processing(label: "Loading model...")),
      (.transcribing, .processing(label: "Transcribing...")),
      (.polishing, .processing(label: "Polishing...")),
      (.recording, .recording(audioLevel: 0)),
      (.error(.modelWedged), .error(reason: .modelWedged)),
    ]
    for (state, intent) in pairs {
      let plan = PipelineStateChangePlanner.plan(
        to: state,
        pipelineOverlayIntent: intent,
        isClipboardFallback: false,
        isAccessibilityToast: false,
        lastPolishError: nil,
        hasCurrentTranscript: false,
        historySaved: true,
        historySaveReason: nil
      )
      #expect(
        plan.effects.contains(.showOverlay(intent)),
        "Expected overlay intent \(intent) preserved for \(state); got \(plan.effects)"
      )
    }
  }

  // PR-5 Rung 5 (#827) deleted: WhisperKit's `.startingUp` + `.loadingModel`
  // bespoke states are gone. The kernel driver's overlay intent now emits
  // "Preparing dictation..." for both `.preparing` and `.warmingUp` (Gate 2:
  // founder accepted the collapsed copy, matching Parakeet's PR-4b.4 shape).

  // MARK: - Error path telemetry

  @Test("error state emits reportPipelineFailed with error code")
  func errorStateEmitsReportPipelineFailed() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.error(.deviceRemoved),
      pipelineOverlayIntent: .error(reason: .deviceRemoved),
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: false,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(plan.effects.contains(.reportPipelineFailed(errorCode: TerminalNoticeReason.deviceRemoved.rawValue)))
    #expect(plan.effects.contains(.cancelPendingWarning))
    #expect(plan.effects.contains(.showOverlay(.error(reason: .deviceRemoved))))
    // error must not trigger .complete-path effects.
    #expect(!plan.effects.contains(.appendCompletedTranscript))
    #expect(!plan.effects.contains(.reportDictationCompleted))
  }

  // PR-5 Rung 5 (#827) deleted: WhisperKit-specific error-state assertion is
  // redundant now that both backends share `PipelineState.error(_)` (covered
  // by `errorStateEmitsReportPipelineFailed` above).

  // MARK: - Effect ordering guarantees

  @Test("complete success plan produces canonical effect order")
  func completeSuccessEffectOrder() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil
    )
    // Order matches the production closure: show overlay, reload history,
    // report telemetry. No warning-cancel, no warning-schedule.
    #expect(
      plan.effects == [
        .showOverlay(.hidden),
        .appendCompletedTranscript,
        .reportDictationCompleted,
      ])
  }

  @Test("complete + polish failed plan produces canonical effect order")
  func completePolishFailedEffectOrder() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: "fail",
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(
      plan.effects == [
        .schedulePolishFailedWarning,
        .showOverlay(.hidden),
        .appendCompletedTranscript,
        .reportDictationCompleted,
      ])
  }

  @Test("complete + clipboard fallback plan produces canonical effect order")
  func completeClipboardFallbackEffectOrder() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      isClipboardFallback: true,
      isAccessibilityToast: false,
      lastPolishError: "fail",
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(
      plan.effects == [
        .showOverlay(.clipboardFallback),
        .appendCompletedTranscript,
        .reportDictationCompleted,
      ])
  }

  @Test("non-complete plan produces cancel-before-show ordering")
  func nonCompleteCancelBeforeShowOrder() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.recording,
      pipelineOverlayIntent: .recording(audioLevel: 0),
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: false,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(
      plan.effects == [
        .cancelPendingWarning,
        .showOverlay(.recording(audioLevel: 0)),
      ])
  }

  @Test("error plan produces cancel, show, report order")
  func errorEffectOrder() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.error(.modelWedged),
      pipelineOverlayIntent: .error(reason: .modelWedged),
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: false,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(
      plan.effects == [
        .cancelPendingWarning,
        .showOverlay(.error(reason: .modelWedged)),
        .reportPipelineFailed(errorCode: TerminalNoticeReason.modelWedged.rawValue),
      ])
  }

  // MARK: - #1167 history-save best-effort

  @Test("complete + history save failed -> pill scheduled, append skipped, telemetry still fires")
  func completeHistorySaveFailedSchedulesPillSkipsAppend() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: false,
      historySaveReason: "disk is full"
    )
    #expect(plan.effects.contains(.scheduleHistorySaveFailedWarning(reason: "disk is full")))
    // Append skipped (so onDurableSave is skipped -> spool retained); the row
    // was never persisted, so an in-memory append would show a phantom entry.
    #expect(!plan.effects.contains(.appendCompletedTranscript))
    // Telemetry still fires so the degraded-save dimension is recorded.
    #expect(plan.effects.contains(.reportDictationCompleted))
  }

  @Test("complete + history save failed + polish failed -> history pill wins the single slot")
  func completeHistorySaveFailedSuppressesPolishWarning() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: "openai 429 rate-limited",
      hasCurrentTranscript: true,
      historySaved: false,
      historySaveReason: "permission denied"
    )
    #expect(plan.effects.contains(.scheduleHistorySaveFailedWarning(reason: "permission denied")))
    #expect(!plan.effects.contains(.schedulePolishFailedWarning))
  }

  @Test("complete + history saved (success) -> append fires, no history pill")
  func completeHistorySavedAppendsNoPill() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil
    )
    #expect(plan.effects.contains(.appendCompletedTranscript))
    #expect(!plan.effects.contains(.scheduleHistorySaveFailedWarning(reason: "disk is full")))
  }

  // MARK: - #1434 salvaged-lead disclosure

  @Test("complete + salvaged lead -> salvage pill scheduled in the single warning slot")
  func salvagedLeadSchedulesPill() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil,
      salvagedLead: true
    )
    #expect(plan.effects.contains(.scheduleSalvagedLeadWarning))
    #expect(plan.effects.contains(.appendCompletedTranscript))
  }

  @Test("complete + salvaged lead + polish failed -> salvage pill wins, polish pill suppressed")
  func salvagedLeadBeatsPolishPill() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: "Polish failed",
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil,
      salvagedLead: true
    )
    #expect(plan.effects.contains(.scheduleSalvagedLeadWarning))
    #expect(!plan.effects.contains(.schedulePolishFailedWarning))
  }

  @Test("complete + salvaged lead + history save failed -> history pill wins the single slot")
  func historyPillBeatsSalvagePill() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: false,
      historySaveReason: "disk is full",
      salvagedLead: true
    )
    #expect(plan.effects.contains(.scheduleHistorySaveFailedWarning(reason: "disk is full")))
    #expect(!plan.effects.contains(.scheduleSalvagedLeadWarning))
  }

  @Test("non-complete transition with salvaged lead does not schedule the pill")
  func salvagePillOnlyOnComplete() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.recording,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: false,
      historySaved: true,
      historySaveReason: nil,
      salvagedLead: true
    )
    #expect(!plan.effects.contains(.scheduleSalvagedLeadWarning))
  }

  // MARK: - #1408 interruption disclosure + the four-way notice ranking

  /// The single post-completion warning slot is last-writer-wins, so the ranking
  /// is not array order — it is a set of suppression conditions in this pure
  /// projection. Parametric over disclosure (nil / .deviceRemoved /
  /// .otherInterruption) × history-save × lead-trim × polish — the full A1
  /// validation matrix from plan §21.3.
  ///
  /// At most one notice per completion: exactly one whenever any claimant
  /// applies, none when no claimant applies. No combination may lose a signal.
  /// The both-ends-lost case (interruption AND lead-trim) is the one that would:
  /// under a plain ranking the user would hear only that the text was cut short,
  /// never that the opening was dropped. It gets its own copy instead.
  @Test(
    "notice ranking: at most one pill per completion, across the full claimant matrix",
    arguments: [false, true],
    [nil, CompletionInterruptionDisclosure.deviceRemoved, .otherInterruption])
  func noticeRankingIsAtMostOnePill(
    historySaveFailed: Bool, disclosure: CompletionInterruptionDisclosure?
  ) {
    for salvagedLead in [false, true] {
      for polishFailed in [false, true] {
        let plan = PipelineStateChangePlanner.plan(
          to: PipelineState.complete,
          pipelineOverlayIntent: Self.hiddenIntent,
          isClipboardFallback: false,
          isAccessibilityToast: false,
          lastPolishError: polishFailed ? "polish failed for some reason" : nil,
          hasCurrentTranscript: true,
          historySaved: !historySaveFailed,
          historySaveReason: historySaveFailed ? "disk full" : nil,
          salvagedLead: salvagedLead,
          interruptionDisclosure: disclosure
        )
        let pills = plan.effects.filter { effect in
          switch effect {
          case .scheduleHistorySaveFailedWarning, .scheduleInterruptionWarning,
            .scheduleSalvagedLeadWarning, .schedulePolishFailedWarning:
            true
          default:
            false
          }
        }
        let label =
          "historySaveFailed=\(historySaveFailed) disclosure=\(String(describing: disclosure)) "
          + "salvagedLead=\(salvagedLead) polishFailed=\(polishFailed)"

        // Exactly one pill when any claimant applies, zero when none does.
        let anyClaimant = historySaveFailed || disclosure != nil || salvagedLead || polishFailed
        #expect(pills.count == (anyClaimant ? 1 : 0), "\(label) -> \(pills)")

        // Rank 1: the history-save pill always wins the slot.
        if historySaveFailed {
          #expect(pills == [.scheduleHistorySaveFailedWarning(reason: "disk full")], "\(label)")
        } else if let disclosure {
          // Rank 2: the interruption pill, carrying BOTH the disclosure (which
          // sentence family) and whether the opening was ALSO lost. This is the
          // signal that must never be dropped — for `.otherInterruption` too
          // (grounded review A1: a non-disconnect salvage must not paste
          // truncated text silently).
          #expect(
            pills == [
              .scheduleInterruptionWarning(disclosure: disclosure, alsoTrimmedLead: salvagedLead)
            ], "\(label)")
        } else if salvagedLead {
          #expect(pills == [.scheduleSalvagedLeadWarning], "\(label)")
        } else if polishFailed {
          #expect(pills == [.schedulePolishFailedWarning], "\(label)")
        }
      }
    }
  }

  @Test(
    "the both-ends-lost completion gets its own copy, for BOTH sentence families",
    arguments: [CompletionInterruptionDisclosure.deviceRemoved, .otherInterruption])
  func bothEndsLostEmitsCombinedNotice(disclosure: CompletionInterruptionDisclosure) {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil,
      salvagedLead: true,
      interruptionDisclosure: disclosure
    )
    #expect(
      plan.effects.contains(
        .scheduleInterruptionWarning(disclosure: disclosure, alsoTrimmedLead: true)))
    #expect(
      !plan.effects.contains(
        .scheduleInterruptionWarning(disclosure: disclosure, alsoTrimmedLead: false)))
    #expect(!plan.effects.contains(.scheduleSalvagedLeadWarning))
  }

  @Test("a history-save failure still outranks the interruption pill")
  func historySaveFailureOutranksInterruption() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: false,
      historySaveReason: "disk full",
      salvagedLead: false,
      interruptionDisclosure: .deviceRemoved
    )
    #expect(plan.effects.contains(.scheduleHistorySaveFailedWarning(reason: "disk full")))
    #expect(
      !plan.effects.contains(
        .scheduleInterruptionWarning(disclosure: .deviceRemoved, alsoTrimmedLead: false)))
  }

  @Test("a non-complete transition with an interruption schedules no pill")
  func interruptionPillOnlyOnComplete() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.recording,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: false,
      historySaved: true,
      historySaveReason: nil,
      salvagedLead: false,
      interruptionDisclosure: .deviceRemoved
    )
    let hasInterruptionPill = plan.effects.contains { effect in
      if case .scheduleInterruptionWarning = effect { return true }
      return false
    }
    #expect(!hasInterruptionPill)
  }

  // MARK: - #1408 A1: the disclosure derivation from the stamped cause

  /// The one mapping the coordinator call sites rely on: nil cause → nil
  /// disclosure; the verified removal → `.deviceRemoved`; every other cause →
  /// `.otherInterruption`. Exhaustive over the cause enum so a new case must
  /// pick a side here at compile time.
  @Test("CompletionInterruptionDisclosure derives from the cause by isDeviceLoss")
  func disclosureDerivation() {
    #expect(CompletionInterruptionDisclosure(cause: nil) == nil)
    for cause in EngineInterruptionCause.allCases {
      let disclosure = CompletionInterruptionDisclosure(cause: cause)
      if cause.isDeviceLoss {
        #expect(disclosure == .deviceRemoved, "\(cause)")
      } else {
        #expect(disclosure == .otherInterruption, "\(cause)")
      }
    }
  }

  // MARK: - Activity projection integrity

  @Test("Parakeet state activity mapping is stable")
  func parakeetActivityMapping() {
    #expect(PipelineState.idle.activity == .idle)
    #expect(PipelineState.loadingModel.activity == .preparing)
    #expect(PipelineState.recording.activity == .recording)
    #expect(PipelineState.transcribing.activity == .processing)
    #expect(PipelineState.polishing.activity == .processing)
    #expect(PipelineState.complete.activity == .complete)
    #expect(PipelineState.error(.modelWedged).activity == .error(.modelWedged))
  }

  // PR-5 Rung 5 (#827) deleted: WhisperKit's bespoke state-activity mapping
  // is gone. Both backends now share `PipelineState`, covered by
  // `parakeetActivityMapping` above.
}
