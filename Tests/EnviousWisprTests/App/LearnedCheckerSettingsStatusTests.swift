import EnviousWisprCore
import EnviousWisprPipeline
import Testing

@testable import EnviousWisprAppKit

@Suite("Dictionary learned-word status (#3105)", .tags(.productOutcome))
struct LearnedCheckerSettingsStatusTests {
  private struct ReadyChecker: LearnedWordChecking {
    let armName = "eg1_lora"
    let scoresAreComparable = true
    func decide(_ questions: [LearnedWordCheckQuestion]) async throws -> [LearnedWordCheckDecision] {
      []
    }
  }

  private let egOne = LearnedWordJudge(displayName: "EG-1")

  @Test("the status line uses the eligibility answer for each visible state")
  func states() {
    let cases: [(LearnedWordCheckerSelection, String, Bool)] = [
      (.init(checker: ReadyChecker(), identity: "eg1c-v2", judge: egOne),
        "Checked by: EG-1. Learned words are checked before they're used.", false),
      (.init(absence: .adapterDownloading, judge: egOne),
        "Learn-only: EG-1's word check is downloading", false),
      (.init(absence: .adapterDeliveryFailed, retryAvailable: true, judge: egOne),
        "Learn-only: EG-1's word check couldn't download", true),
      (.init(absence: .adapterDeliveryFailed, judge: egOne),
        "Learn-only: EG-1's word check isn't available yet", false),
      (.init(absence: .deliveryDisabled, judge: egOne),
        "Learn-only: EG-1's word check isn't available yet", false),
      (.init(absence: .engineHasNoChecker), "Learn-only: This polish choice", false),
    ]
    for (selection, prefix, retry) in cases {
      let status = LearnedCheckerSettingsStatus(selection: selection)
      #expect(status.line.hasPrefix(prefix))
      #expect(status.canRetry == retry)
    }
  }

  @Test("a new judge reaches the copy without a copy edit, and the line names no language")
  func judgeNamesItself() {
    let judge = LearnedWordJudge(displayName: "S1-mini")
    #expect(LearnedCheckerSettingsStatus(selection: .init(
      checker: ReadyChecker(), identity: "s1c-d5", judge: judge)).line
      == "Checked by: S1-mini. Learned words are checked before they're used.")
  }

  @Test("all Dictionary status copy avoids internal terms")
  func copyIsPlainEnglish() {
    let reasons: [LearnedWordCheckerAbsence] = [
      .adapterDownloading, .adapterDeliveryFailed, .engineHasNoChecker,
      .baseNotAdmitted, .baseMismatch("revision"), .serverWithoutAdapter("adapter_missing"),
      .serverUnavailable, .deliveryDisabled,
    ]
    let lines = reasons.map { LearnedCheckerSettingsStatus(selection: .init(absence: $0)).line }
      + [LearnedCheckerSettingsStatus(selection: .init(
        checker: ReadyChecker(), identity: "eg1c-v2")).line,
        String(localized: LearnedCheckerSettingsStatus.retryTitle)]
    for line in lines {
      let lower = line.lowercased()
      #expect(!lower.contains("adapter"))
      #expect(!lower.contains("lora"))
      #expect(!lower.contains("checker"))
    }
  }
}
