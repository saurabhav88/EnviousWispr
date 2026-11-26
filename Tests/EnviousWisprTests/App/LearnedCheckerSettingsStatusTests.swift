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
    let cases: [(LearnedWordCheckerSelection, String, Bool, LearnFromEditsSettingsPresentation.StatusWord)] = [
      (.init(checker: ReadyChecker(), identity: "eg1c-v2", judge: egOne),
        "Available with EG-1", false, .ready),
      (.init(absence: .adapterDownloading, judge: egOne),
        "EG-1's word check is downloading", false, .notReady),
      (.init(absence: .adapterDeliveryFailed, retryAvailable: true, judge: egOne),
        "EG-1's word check couldn't download", true, .notReady),
      (.init(absence: .adapterDeliveryFailed, judge: egOne),
        "EG-1's word check isn't available yet", false, .notReady),
      (.init(absence: .deliveryDisabled, judge: egOne),
        "EG-1's word check isn't available yet", false, .notReady),
      (.init(absence: .engineHasNoChecker), "This polish choice", false, .notAvailable),
    ]
    for (selection, prefix, retry, readiness) in cases {
      let status = LearnedCheckerSettingsStatus(selection: selection)
      #expect(status.line.hasPrefix(prefix))
      #expect(status.canRetry == retry)
      #expect(status.readiness == readiness)
    }
    // #5006: the shared word check's own ready status, read without its model.
    #expect(LearnedCheckerSettingsStatus(checkedBy: egOne).readiness == .ready)
  }

  @Test("with Enable Dictionary off the row shows no word-check status (#3255)")
  func dictionaryOffShowsNoStatus() {
    let ready = LearnedCheckerSettingsStatus(selection: .init(
      checker: ReadyChecker(), identity: "eg1c-v2", judge: egOne))
    let downloading = LearnedCheckerSettingsStatus(selection: .init(
      absence: .adapterDownloading, judge: egOne))
    for status in [ready, downloading] {
      #expect(LearnedCheckerSettingsStatus.shown(status, dictionaryEnabled: false) == nil)
      #expect(LearnedCheckerSettingsStatus.shown(status, dictionaryEnabled: true) == status)
    }
    #expect(LearnedCheckerSettingsStatus.shown(nil, dictionaryEnabled: true) == nil)
  }

  @Test("a new judge reaches the copy without a copy edit, and the line names no language")
  func judgeNamesItself() {
    let judge = LearnedWordJudge(displayName: "S1-mini")
    #expect(LearnedCheckerSettingsStatus(selection: .init(
      checker: ReadyChecker(), identity: "s1c-d5", judge: judge)).line
      == "Available with S1-mini")
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
