import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Which judge serves on which macOS (#996 plan §3.1 step 7). When this
/// fails, a Mac gets suggestions from a judge that was never proven on the
/// report set, or a proven judge is withheld.
@Suite("CorrectionJudgeArmSelection — measured qualification decides (#996)", .tags(.productOutcome))
struct CorrectionJudgeArmSelectionTests {

  private let rulesDigest = "rules-digest"
  private let afmDigest = "afm-digest"

  private func rules(_ majors: Set<Int>, digest: String? = nil) -> CorrectionJudgeQualification {
    CorrectionJudgeQualification(
      arm: .rules, osMajors: majors, configDigest: digest ?? rulesDigest, receipt: "r")
  }
  private func afm(_ majors: Set<Int>, digest: String? = nil) -> CorrectionJudgeQualification {
    CorrectionJudgeQualification(
      arm: .afm, osMajors: majors, configDigest: digest ?? afmDigest, receipt: "a")
  }

  private func select(
    _ major: Int, afmAvailable: Bool = true, _ table: [CorrectionJudgeQualification]
  ) -> CorrectionJudgeArmSelection {
    CorrectionJudgeArmSelection.select(
      osMajor: major, afmAvailable: afmAvailable, rulesDigest: rulesDigest, afmDigest: afmDigest,
      qualified: table)
  }

  @Test("below the AFM floor, qualified rules serve")
  func rulesBelowFloor() {
    #expect(select(15, [rules([14, 15])]) == .arm(.rules))
    #expect(select(14, [rules([14, 15])]) == .arm(.rules))
  }

  @Test("below the floor with nothing qualified, nothing serves")
  func nothingBelowFloor() {
    #expect(select(15, []) == .unavailable(.noQualifiedArm))
  }

  @Test("a qualification under another digest is not a qualification")
  func staleDigestIsRevoked() {
    #expect(select(15, [rules([15], digest: "older-rules")]) == .unavailable(.noQualifiedArm))
    #expect(select(27, [afm([27], digest: "older-prompt")]) == .unavailable(.noQualifiedArm))
  }

  @Test("an AFM entry below the floor is ignored even when the model claims availability")
  func afmIgnoredBelowFloor() {
    #expect(select(15, afmAvailable: true, [afm([15])]) == .unavailable(.noQualifiedArm))
  }

  @Test("at the floor and above, qualified and available AFM serves")
  func afmServes() {
    #expect(select(27, afmAvailable: true, [afm([27]), rules([27])]) == .arm(.afm))
  }

  @Test("AFM switched off falls back to independently qualified rules")
  func rulesFallback() {
    #expect(select(27, afmAvailable: false, [afm([27]), rules([27])]) == .arm(.rules))
  }

  @Test("AFM switched off with no qualified rules names the reason")
  func afmOffNoFallback() {
    #expect(select(27, afmAvailable: false, [afm([27])]) == .unavailable(.afmUnavailableNoRulesFallback))
  }

  @Test("AFM available but unqualified serves nothing even with the framework present")
  func frameworkPresenceIsNotQualification() {
    #expect(select(27, afmAvailable: true, []) == .unavailable(.noQualifiedArm))
  }

  @Test("a report on macOS 27 says nothing about macOS 26")
  func macOS26Excluded() {
    #expect(select(27, [afm([27])]) == .arm(.afm))
    #expect(select(26, [afm([27])]) == .unavailable(.noQualifiedArm))
    #expect(select(26, [afm([27]), rules([26])]) == .arm(.rules))
  }

  @Test("the shipped table binds live digests: an entry whose digest no longer matches is dead")
  func shippedTableBindsLiveDigests() async {
    let liveRules = RulesCorrectionJudge.configDigest(policy: .v1)
    let liveAFM = WordSuggestionService.correctionJudgeConfigDigest
    for entry in CorrectionJudgeArmSelection.qualified {
      switch entry.arm {
      case .rules: #expect(entry.configDigest == liveRules, "\(entry.receipt)")
      case .afm: #expect(entry.configDigest == liveAFM, "\(entry.receipt)")
      }
      #expect(entry.osMajors.isEmpty == false)
      #expect(entry.receipt.isEmpty == false)
    }
  }
}
