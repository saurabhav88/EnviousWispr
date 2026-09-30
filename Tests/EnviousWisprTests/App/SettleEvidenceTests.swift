import EnviousWisprCore
import EnviousWisprServices
import Testing

@testable import EnviousWisprAppKit

/// #3101: how strongly the observer knows an edit is finished, and what the
/// watcher demands of the judge for each. When this fails, a half-typed word
/// ("Tipu" -> "Tippecan") is learned on a pause or an app switch, or a
/// finished fix taught by a caret move or a send stops being learned.
@Suite(.tags(.productOutcome))
struct SettleEvidenceTests {

  @Test("only a caret that left the edit is strong settle evidence")
  func settleTriggers() {
    #expect(PastedRegionObserver.SettleTrigger.caretLeft.evidence == .strong)
    #expect(PastedRegionObserver.SettleTrigger.cap.evidence == .weak)
    #expect(PastedRegionObserver.SettleTrigger.fallbackQuiet.evidence == .weak)
  }

  @Test("send-shaped ends flush as strong, focus and ceiling as weak, the rest never flush")
  func endReasons() {
    // An independent table: every end reason, so a new one fails here until chosen.
    let expected: [PastedRegionEndReason: SettleEvidence?] = [
      .textboxEmptied: .strong, .elementDestroyed: .strong, .appTerminated: .strong,
      .regionRemoved: .strong, .anchorAmbiguous: .strong, .editDistanceExceeded: .strong,
      .nextDictationStarted: .strong,
      .focusChanged: .weak, .ceilingElapsed: .weak,
      .settled: nil, .dictatedTextNotFound: nil, .captureUnsupported: nil, .permissionLost: nil,
    ]
    #expect(Set(expected.keys) == Set(PastedRegionEndReason.allCases))
    for reason in PastedRegionEndReason.allCases {
      #expect(reason.pendingEvidence == expected[reason] ?? nil, "\(reason)")
      // A reason that flushes carries evidence; one that never flushes carries none.
      #expect((reason.pendingEvidence != nil) == reason.flushesPendingEdit, "\(reason)")
    }
  }

  @Test("weak evidence needs the higher judge score; strong evidence and a scoreless arm do not")
  func acceptance() {
    let t = ObservedCorrectionWatcher.weakEvidenceThreshold
    #expect(t == 0.95)
    func accepts(_ verdict: CorrectionJudgeClass, _ p: Double?, _ e: SettleEvidence) -> Bool {
      ObservedCorrectionWatcher.accepts(
        CorrectionJudgeDecision(id: 1, verdict: verdict, probability: p), evidence: e)
    }
    // Strong: today's rule, the verdict alone.
    #expect(accepts(.correctionButUnsafe, 0.70, .strong))
    #expect(accepts(.correctionButUnsafe, nil, .strong))
    #expect(accepts(.notCorrection, 0.99, .strong) == false)
    // Weak: the score must reach the threshold.
    #expect(accepts(.correctionButUnsafe, t, .weak))
    #expect(accepts(.correctionButUnsafe, 0.996, .weak))
    #expect(accepts(.correctionButUnsafe, 0.949, .weak) == false)
    #expect(accepts(.correctionButUnsafe, 0.70, .weak) == false)
    #expect(accepts(.notCorrection, 0.99, .weak) == false)
    // A scoreless arm (rules, Apple) keeps today's behaviour.
    #expect(accepts(.correctionButUnsafe, nil, .weak))
    // A malformed score never passes.
    #expect(accepts(.correctionButUnsafe, .nan, .weak) == false)
    #expect(accepts(.correctionButUnsafe, 1.5, .weak) == false)
  }
}
