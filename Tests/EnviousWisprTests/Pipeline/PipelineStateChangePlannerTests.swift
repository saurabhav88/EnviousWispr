import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Characterization tests pinning the current behavior of the state-change
/// closures at `AppState.swift:344-406` (Parakeet) and `:409-463` (WhisperKit).
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
      hasCurrentTranscript: true
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
      hasCurrentTranscript: true
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
      hasCurrentTranscript: true
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
      hasCurrentTranscript: true
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
      hasCurrentTranscript: true
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
      hasCurrentTranscript: true
    )
    #expect(plan.effects.contains(.showOverlay(.hidden)))
    #expect(plan.effects.contains(.schedulePolishFailedWarning))
    #expect(plan.effects.contains(.appendCompletedTranscript))
    #expect(plan.effects.contains(.reportDictationCompleted))
    #expect(!plan.effects.contains(.cancelPendingWarning))
  }

  @Test("complete + success (no fallback, no polish error) -> no warning, telemetry fires")
  func completeSuccessEmitsNoWarning() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: true
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
      hasCurrentTranscript: false
    )
    #expect(!plan.effects.contains(.appendCompletedTranscript))
    #expect(!plan.effects.contains(.reportDictationCompleted))
  }

  // MARK: - Warning cancellation on non-complete transitions

  @Test("non-complete transitions cancel pending warning")
  func nonCompleteTransitionsCancelWarning() {
    let nonCompleteStates: [PipelineState] = [
      .idle, .loadingModel, .recording, .transcribing, .polishing, .error("boom"),
    ]
    for state in nonCompleteStates {
      let plan = PipelineStateChangePlanner.plan(
        to: state,
        pipelineOverlayIntent: Self.recordingIntent,
        isClipboardFallback: false,
        isAccessibilityToast: false,
        lastPolishError: nil,
        hasCurrentTranscript: false
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

  @Test("WhisperKit .ready cancels warning (activity == .idle)")
  func whisperKitReadyCancelsWarning() {
    // .ready is WhisperKit-only; bible §7.6 + tests/Phase A focus specifically
    // on its classification. PipelineStateProtocol maps it to activity .idle,
    // so it hits the non-complete branch.
    let plan = PipelineStateChangePlanner.plan(
      to: WhisperKitPipelineState.ready,
      pipelineOverlayIntent: Self.hiddenIntent,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: false
    )
    #expect(plan.effects.first == .cancelPendingWarning)
    #expect(plan.effects.contains(.showOverlay(.hidden)))
    #expect(!plan.effects.contains(.appendCompletedTranscript))
    #expect(!plan.effects.contains(.reportDictationCompleted))
  }

  // MARK: - Overlay intent pass-through (no label flattening)

  @Test("pipeline overlay intent passes through verbatim for non-complete states")
  func pipelineOverlayIntentPassesThroughVerbatim() {
    let pairs: [(PipelineState, OverlayIntent)] = [
      (.loadingModel, .processing(label: "Loading model...")),
      (.transcribing, .processing(label: "Transcribing...")),
      (.polishing, .processing(label: "Polishing...")),
      (.recording, .recording(audioLevel: 0)),
      (.error("boom"), .error(message: "boom")),
    ]
    for (state, intent) in pairs {
      let plan = PipelineStateChangePlanner.plan(
        to: state,
        pipelineOverlayIntent: intent,
        isClipboardFallback: false,
        isAccessibilityToast: false,
        lastPolishError: nil,
        hasCurrentTranscript: false
      )
      #expect(
        plan.effects.contains(.showOverlay(intent)),
        "Expected overlay intent \(intent) preserved for \(state); got \(plan.effects)"
      )
    }
  }

  @Test("WhisperKit startingUp vs loadingModel labels are preserved distinctly")
  func whisperKitStartingUpAndLoadingModelLabelsPreserved() {
    // Guard against collapsing these two user-visible labels into a single
    // coarse "preparing" bucket (bible §7.2 correction).
    let startingUp = PipelineStateChangePlanner.plan(
      to: WhisperKitPipelineState.startingUp,
      pipelineOverlayIntent: .processing(label: "Starting..."),
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: false
    )
    let loadingModel = PipelineStateChangePlanner.plan(
      to: WhisperKitPipelineState.loadingModel,
      pipelineOverlayIntent: .processing(label: "Loading model..."),
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: false
    )
    #expect(startingUp.effects.contains(.showOverlay(.processing(label: "Starting..."))))
    #expect(loadingModel.effects.contains(.showOverlay(.processing(label: "Loading model..."))))
  }

  // MARK: - Error path telemetry

  @Test("error state emits reportPipelineFailed with error code")
  func errorStateEmitsReportPipelineFailed() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.error("mic_disconnected"),
      pipelineOverlayIntent: .error(message: "mic_disconnected"),
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: false
    )
    #expect(plan.effects.contains(.reportPipelineFailed(errorCode: "mic_disconnected")))
    #expect(plan.effects.contains(.cancelPendingWarning))
    #expect(plan.effects.contains(.showOverlay(.error(message: "mic_disconnected"))))
    // error must not trigger .complete-path effects.
    #expect(!plan.effects.contains(.appendCompletedTranscript))
    #expect(!plan.effects.contains(.reportDictationCompleted))
  }

  @Test("WhisperKit error state emits reportPipelineFailed")
  func whisperKitErrorStateEmitsReportPipelineFailed() {
    let plan = PipelineStateChangePlanner.plan(
      to: WhisperKitPipelineState.error("whisperkit_load_failed"),
      pipelineOverlayIntent: .error(message: "whisperkit_load_failed"),
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: false
    )
    #expect(plan.effects.contains(.reportPipelineFailed(errorCode: "whisperkit_load_failed")))
  }

  // MARK: - Effect ordering guarantees

  @Test("complete success plan produces canonical effect order")
  func completeSuccessEffectOrder() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: true
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
      hasCurrentTranscript: true
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
      hasCurrentTranscript: true
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
      hasCurrentTranscript: false
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
      to: PipelineState.error("bad"),
      pipelineOverlayIntent: .error(message: "bad"),
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: false
    )
    #expect(
      plan.effects == [
        .cancelPendingWarning,
        .showOverlay(.error(message: "bad")),
        .reportPipelineFailed(errorCode: "bad"),
      ])
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
    #expect(PipelineState.error("x").activity == .error("x"))
  }

  @Test("WhisperKit state activity mapping covers ready + startingUp")
  func whisperKitActivityMapping() {
    #expect(WhisperKitPipelineState.idle.activity == .idle)
    #expect(WhisperKitPipelineState.ready.activity == .idle)
    #expect(WhisperKitPipelineState.startingUp.activity == .preparing)
    #expect(WhisperKitPipelineState.loadingModel.activity == .preparing)
    #expect(WhisperKitPipelineState.recording.activity == .recording)
    #expect(WhisperKitPipelineState.transcribing.activity == .processing)
    #expect(WhisperKitPipelineState.polishing.activity == .processing)
    #expect(WhisperKitPipelineState.complete.activity == .complete)
    #expect(WhisperKitPipelineState.error("x").activity == .error("x"))
  }
}
