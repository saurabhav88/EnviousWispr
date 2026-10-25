import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

@testable import EnviousWisprAppKit
import EnviousWisprAppKitTestSupport

// MARK: - Test doubles shared by the watcher, wiring and composition suites (#996)

extension LearnMemory {
  /// A learning memory on its own empty temporary file (#3975), never the
  /// live Application Support store.
  @MainActor
  static func forTests() -> LearnMemory {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-learn-memory-\(UUID().uuidString)", isDirectory: true)
    return LearnMemory(fileURL: dir.appendingPathComponent(LearnMemory.fileName))
  }
}

/// Records every learn-from-edits emission the watcher and the learned
/// coordinator make: the runtime sink's nine events, nothing else.
@MainActor
final class LearnTelemetrySpy: LearnFromEditsRuntimeTelemetrySink {
  enum Event: Equatable {
    // The watcher's four (`LearnFromEditsTelemetrySink`).
    case skipped(T.SkipReason)
    case observationEnded(PastedRegionEndReason, Int, T.AppClass)
    case judged(T.Arm, T.JudgeOutcome, Int, Int)
    case blockedSeen(String?)
    // The learned coordinator's five (`LearnedCorrectionTelemetrySink`).
    case saveFailed(T.SaveFailure)
    case added(T.AddedState, T.LearnVia)
    case undoShown
    case undone(T.UndoKind, T.UndoOutcome, T.LearnVia, T.UndoMemory?)
    case refusedByUser(T.RefusalSource, T.UndoMemory)
  }
  private(set) var events: [Event] = []

  /// The take id of every watcher emission, in order (#3105).
  private(set) var takeIDs: [String?] = []
  /// #3101: the completion evidence each judge call reported.
  private(set) var judgedEvidence: [SettleEvidence] = []
  /// The loss detail of every ended observation, in order (#3105).
  private(set) var regionDetails: [PastedRegionEndDetail?] = []
  func learnSkipped(reason: T.SkipReason, takeID: String?) {
    takeIDs.append(takeID)
    events.append(.skipped(reason))
  }
  /// `unfinished_edits` per ended observation, in order (#3105).
  private(set) var unfinishedEditCounts: [Int] = []
  func learnObservationEnded(
    reason: PastedRegionEndReason, settledBursts: Int, appClass: T.AppClass, durationMs: Int,
    unfinishedEdits: Int, takeID: String?, regionDetail: PastedRegionEndDetail?
  ) {
    takeIDs.append(takeID)
    regionDetails.append(regionDetail)
    unfinishedEditCounts.append(unfinishedEdits)
    events.append(.observationEnded(reason, settledBursts, appClass))
  }
  func learnJudged(
    arm: T.Arm, outcome: T.JudgeOutcome, candidates: Int, accepted: Int, latencyMs: Int,
    queueWaitMs: Int?, takeID: String?, evidence: SettleEvidence
  ) {
    takeIDs.append(takeID)
    judgedEvidence.append(evidence)
    events.append(.judged(arm, outcome, candidates, accepted))
  }
  func learnBlockedSeen(takeID: String?) { events.append(.blockedSeen(takeID)) }
  func learnSaveFailed(reason: T.SaveFailure) { events.append(.saveFailed(reason)) }
  func learnAdded(state: T.AddedState, via: T.LearnVia) { events.append(.added(state, via)) }
  func learnUndoShown() { events.append(.undoShown) }
  func learnUndone(kind: T.UndoKind, outcome: T.UndoOutcome, via: T.LearnVia, memory: T.UndoMemory?) {
    events.append(.undone(kind, outcome, via, memory))
  }
  func learnRefusedByUser(source: T.RefusalSource, result: T.UndoMemory) {
    events.append(.refusedByUser(source, result))
  }
}
