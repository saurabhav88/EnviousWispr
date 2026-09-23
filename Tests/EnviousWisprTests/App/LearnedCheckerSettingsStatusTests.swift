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

  @Test("the status line uses the eligibility answer for each visible state")
  func states() {
    let cases: [(LearnedWordCheckerSelection, String, Bool)] = [
      (.init(checker: ReadyChecker(), identity: "eg1c-v1"), "Checked by: EG-1", false),
      (.init(absence: .adapterDownloading), "Learn-only: EG-1's word check is downloading", false),
      (.init(absence: .adapterDeliveryFailed, retryAvailable: true),
        "Learn-only: EG-1's word check couldn't download", true),
      (.init(absence: .adapterDeliveryFailed), "Learn-only: EG-1's word check isn't available yet", false),
      (.init(absence: .notEGOne), "Learn-only: This polish choice", false),
      (.init(absence: .unqualifiedLanguage), "Learn-only: Learned words are checked in English only", false),
    ]
    for (selection, prefix, retry) in cases {
      let status = LearnedCheckerSettingsStatus(selection: selection)
      #expect(status.line.hasPrefix(prefix))
      #expect(status.canRetry == retry)
    }
  }

  @Test("all Dictionary status copy avoids internal terms")
  func copyIsPlainEnglish() {
    let reasons: [LearnedWordCheckerAbsence] = [
      .adapterDownloading, .adapterDeliveryFailed, .notEGOne, .unqualifiedLanguage,
      .baseNotAdmitted, .baseMismatch("revision"), .serverWithoutAdapter("adapter_missing"),
      .serverUnavailable,
    ]
    let lines = reasons.map { LearnedCheckerSettingsStatus(selection: .init(absence: $0)).line }
      + [LearnedCheckerSettingsStatus(selection: .init(
        checker: ReadyChecker(), identity: "eg1c-v1")).line,
        LearnedCheckerSettingsStatus.retryTitle]
    for line in lines {
      let lower = line.lowercased()
      #expect(!lower.contains("adapter"))
      #expect(!lower.contains("lora"))
      #expect(!lower.contains("checker"))
    }
  }
}
