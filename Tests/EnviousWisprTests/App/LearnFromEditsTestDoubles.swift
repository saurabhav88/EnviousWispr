import EnviousWisprCore
import EnviousWisprServices
import Foundation

@testable import EnviousWisprAppKit

// MARK: - Test doubles shared by the watcher, wiring and composition suites (#996)

/// Records every learn-from-edits emission the watcher and the learned
/// coordinator make: the runtime sink's seven events, nothing else.
@MainActor
final class LearnTelemetrySpy: LearnFromEditsRuntimeTelemetrySink {
  enum Event: Equatable {
    // The watcher's three (`LearnFromEditsTelemetrySink`).
    case skipped(T.SkipReason)
    case observationEnded(PastedRegionEndReason, Int, T.AppClass)
    case judged(T.Arm, T.JudgeOutcome, Int, Int)
    // The learned coordinator's four (`LearnedCorrectionTelemetrySink`).
    case saveFailed(T.SaveFailure)
    case added(T.AddedState)
    case undoShown
    case undone(T.UndoKind, T.UndoOutcome)
  }
  private(set) var events: [Event] = []

  func learnSkipped(reason: T.SkipReason) { events.append(.skipped(reason)) }
  func learnObservationEnded(
    reason: PastedRegionEndReason, settledBursts: Int, appClass: T.AppClass, durationMs: Int
  ) {
    events.append(.observationEnded(reason, settledBursts, appClass))
  }
  func learnJudged(
    arm: T.Arm, outcome: T.JudgeOutcome, candidates: Int, accepted: Int, latencyMs: Int,
    queueWaitMs: Int?
  ) {
    events.append(.judged(arm, outcome, candidates, accepted))
  }
  func learnSaveFailed(reason: T.SaveFailure) { events.append(.saveFailed(reason)) }
  func learnAdded(state: T.AddedState) { events.append(.added(state)) }
  func learnUndoShown() { events.append(.undoShown) }
  func learnUndone(kind: T.UndoKind, outcome: T.UndoOutcome) {
    events.append(.undone(kind, outcome))
  }
}
