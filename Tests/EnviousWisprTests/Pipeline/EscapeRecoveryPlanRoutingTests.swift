import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// What a concluded Escape Recovery turns into, from the planner's decision to
/// the handler's calls (#2087, chunk 6).
///
/// The rule under test is an EXCLUSION, and exclusions are the kind that ship
/// broken: a saved recovery must take over the completion path, not run beside
/// it. Running beside it would put one dictation in History twice under two
/// identities and count a cancelled take as a delivered one — both visible to
/// the user, neither a crash.
@MainActor
@Suite("Escape Recovery plan routing (#2087)")
struct EscapeRecoveryPlanRoutingTests {

  // MARK: Planner

  @Test("a saved recovery replaces the ordinary completion effects rather than joining them")
  func savedRecoveryReplacesOrdinaryCompletion() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil,
      escapeRecoveryOutcome: .saved)

    #expect(plan.effects.contains(.appendPendingTranscript))
    #expect(plan.effects.contains(.presentEscapeRecoveryPill))
    #expect(plan.effects.contains(.reportEscapeRecoveryCompleted(outcome: .saved)))
    #expect(
      !plan.effects.contains(.appendCompletedTranscript),
      "the row lives in pending/, and a second append would show it twice")
    #expect(
      !plan.effects.contains(.reportDictationCompleted),
      "a cancelled take is not a delivered dictation")
  }

  /// The control for the exclusion above. Identical inputs minus the outcome
  /// must still produce today's completion effects — otherwise the test above
  /// would pass against a planner that had simply stopped emitting them.
  @Test("without a recovery outcome the completion path is untouched")
  func ordinaryCompletionIsUnchanged() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: true,
      historySaved: true,
      historySaveReason: nil)

    #expect(plan.effects.contains(.appendCompletedTranscript))
    #expect(plan.effects.contains(.reportDictationCompleted))
    #expect(!plan.effects.contains(.appendPendingTranscript))
    #expect(!plan.effects.contains(.presentEscapeRecoveryPill))
  }

  /// Enumerated over the closed set rather than spot-checked, so a SIXTH
  /// outcome added later cannot quietly default into offering a pill.
  @Test("no outcome but saved appends a row or offers a pill")
  func onlySavedAppendsOrOffers() {
    for outcome in EscapeRecoveryTerminalOutcome.allCases where outcome != .saved {
      let plan = PipelineStateChangePlanner.plan(
        to: PipelineState.complete,
        pipelineOverlayIntent: .hidden,
        isClipboardFallback: false,
        isAccessibilityToast: false,
        lastPolishError: nil,
        hasCurrentTranscript: true,
        historySaved: true,
        historySaveReason: nil,
        escapeRecoveryOutcome: outcome)

      #expect(plan.effects.contains(.reportEscapeRecoveryCompleted(outcome: outcome)))
      #expect(
        !plan.effects.contains(.presentEscapeRecoveryPill),
        "\(outcome.rawValue) has nothing to give back")
      #expect(
        !plan.effects.contains(.appendPendingTranscript),
        "\(outcome.rawValue) wrote no row")
      #expect(!plan.effects.contains(.appendCompletedTranscript))
      #expect(!plan.effects.contains(.reportDictationCompleted))
    }
  }

  /// Abandonment concludes on the `.idle` callback, not on `.complete`. The
  /// outcome must still be reported there — a user who deliberately discarded
  /// their text is the single most important thing this feature can learn, and
  /// gating the report on `.complete` would lose exactly that population.
  @Test("an abandoned recovery reports on a terminal that is not complete")
  func abandonedReportsOffTheCompletePath() {
    let plan = PipelineStateChangePlanner.plan(
      to: PipelineState.idle,
      pipelineOverlayIntent: .hidden,
      isClipboardFallback: false,
      isAccessibilityToast: false,
      lastPolishError: nil,
      hasCurrentTranscript: false,
      historySaved: false,
      historySaveReason: nil,
      escapeRecoveryOutcome: .abandoned)

    #expect(plan.effects.contains(.reportEscapeRecoveryCompleted(outcome: .abandoned)))
    #expect(!plan.effects.contains(.presentEscapeRecoveryPill))
  }

  // MARK: Handler

  @Test("the handler routes a saved completion to the pending append, the pill and the report")
  func handlerRoutesSavedCompletion() {
    let recorder = Recorder()
    let handler = makeHandler(recorder)
    let transcript = Transcript(text: "held, not pasted")
    let payload = CancelUndoPayload(
      transcriptID: transcript.id, targetApp: nil, targetElement: nil)

    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: transcript,
      historySaved: true,
      historySaveReason: nil,
      escapeRecoveryCompletion: .saved(payload))

    #expect(recorder.pendingAppends.map(\.id) == [transcript.id])
    #expect(recorder.pillPayloads.map(\.transcriptID) == [transcript.id])
    #expect(recorder.outcomes == [.saved])
    #expect(recorder.completedAppends.isEmpty, "the ordinary append must not also fire")
  }

  @Test("the handler offers no pill for an outcome that saved nothing")
  func handlerOffersNoPillWithoutASavedRow() {
    let recorder = Recorder()
    let handler = makeHandler(recorder)

    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: Transcript(text: "never written"),
      historySaved: false,
      historySaveReason: nil,
      escapeRecoveryCompletion: .nothingToRestore(.saveFailed))

    #expect(recorder.pillPayloads.isEmpty)
    #expect(recorder.pendingAppends.isEmpty)
    #expect(recorder.outcomes == [.saveFailed])
  }

  /// The handler's control: with no completion in hand it must behave exactly as
  /// it does today, including for callers that never pass the parameter at all.
  @Test("the handler is untouched when no recovery concluded")
  func handlerUnchangedWithoutACompletion() {
    let recorder = Recorder()
    let handler = makeHandler(recorder)
    let transcript = Transcript(text: "an ordinary dictation")

    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: transcript,
      historySaved: true,
      historySaveReason: nil)

    #expect(recorder.completedAppends.map(\.id) == [transcript.id])
    #expect(recorder.pendingAppends.isEmpty)
    #expect(recorder.pillPayloads.isEmpty)
    #expect(recorder.outcomes.isEmpty)
  }

  // MARK: Helpers

  private final class Recorder {
    var completedAppends: [Transcript] = []
    var pendingAppends: [Transcript] = []
    var pillPayloads: [CancelUndoPayload] = []
    var outcomes: [EscapeRecoveryTerminalOutcome] = []
  }

  private func makeHandler(_ r: Recorder) -> PipelineStateChangeHandler {
    PipelineStateChangeHandler(
      showOverlay: { _ in },
      cancelPendingWarning: {},
      schedulePolishFailedWarning: {},
      appendCompletedTranscript: { r.completedAppends.append($0) },
      reportDictationCompleted: { _ in },
      reportPipelineFailed: { _ in },
      scheduleHistorySaveFailedWarning: { _ in },
      appendPendingTranscript: { r.pendingAppends.append($0) },
      presentEscapeRecoveryPill: { r.pillPayloads.append($0) },
      reportEscapeRecoveryCompleted: { outcome, _ in r.outcomes.append(outcome) })
  }
}
