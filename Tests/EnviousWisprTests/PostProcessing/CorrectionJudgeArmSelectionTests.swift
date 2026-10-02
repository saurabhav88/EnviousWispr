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

  private let classifierDigest = "classifier-identity-digest"
  /// The delivered classifier's identity, an independent literal (`DeliveryManifestTests` pins the
  /// manifest side), so rows against the SHIPPED table exercise real rows.
  private static let shippedClassifierDigest =
    "73d1c5147945dff0b7aa8ba0bd5de8669750955eaf4f51895c1741b4575adb2a"

  private func classifier(_ majors: Set<Int>, digest: String? = nil) -> CorrectionJudgeQualification {
    CorrectionJudgeQualification(
      arm: .classifier, osMajors: majors, configDigest: digest ?? classifierDigest, receipt: "c")
  }

  private func select(
    _ major: Int, afmAvailable: Bool = true, loadedClassifier: String? = nil,
    _ table: [CorrectionJudgeQualification]
  ) -> CorrectionJudgeArmSelection {
    CorrectionJudgeArmSelection.select(
      osMajor: major, afmAvailable: afmAvailable, rulesDigest: rulesDigest, afmDigest: afmDigest,
      classifierDigest: loadedClassifier, qualified: table)
  }

  @Test("#996 phase D: a loaded, qualified classifier serves first on any macOS it was examined on")
  func classifierServesFirst() {
    #expect(select(27, loadedClassifier: classifierDigest, [classifier([27]), afm([27]), rules([27])]) == .arm(.classifier))
    #expect(select(14, loadedClassifier: classifierDigest, [classifier([14, 27])]) == .arm(.classifier))
  }

  @Test("#996 phase D: an unloaded, mismatched or OS-unqualified classifier never serves")
  func classifierNeverServesSilently() {
    // Not loaded yet (admitted, downloading, failed, kill switch off): nil digest.
    #expect(select(27, loadedClassifier: nil, [classifier([27])]) == .unavailable(.noQualifiedArm))
    // Loaded, but not the examined identity (other package, tokenizer or threshold).
    #expect(select(27, loadedClassifier: "another-package", [classifier([27])]) == .unavailable(.noQualifiedArm))
    // Loaded and examined, but on a macOS the receipt does not cover.
    #expect(select(26, loadedClassifier: classifierDigest, [classifier([27])]) == .unavailable(.noQualifiedArm))
    // Falls through to the older rungs when those are qualified.
    #expect(select(27, loadedClassifier: nil, [classifier([27]), afm([27])]) == .arm(.afm))
    #expect(CorrectionJudgeArmSelection.classifierIsQualifiedSomewhere(digest: classifierDigest, osMajor: 27, qualified: [afm([27])]) == false)
    #expect(CorrectionJudgeArmSelection.classifierIsQualifiedSomewhere(digest: "other", osMajor: 27, qualified: [classifier([27])]) == false)
    #expect(CorrectionJudgeArmSelection.classifierIsQualifiedSomewhere(digest: nil, osMajor: 27, qualified: [classifier([27])]) == false)
    #expect(CorrectionJudgeArmSelection.classifierIsQualifiedSomewhere(digest: classifierDigest, osMajor: 27, qualified: [classifier([27])]) == true)
    // #3092: the download gate follows the Mac's own major, as `select` does. A receipt for 27 alone
    // must not start the download on 26 or 14, and a major with its own receipt still downloads.
    #expect(CorrectionJudgeArmSelection.classifierIsQualifiedSomewhere(digest: classifierDigest, osMajor: 26, qualified: [classifier([27])]) == false)
    #expect(CorrectionJudgeArmSelection.classifierIsQualifiedSomewhere(digest: classifierDigest, osMajor: 14, qualified: [classifier([27])]) == false)
    #expect(CorrectionJudgeArmSelection.classifierIsQualifiedSomewhere(digest: classifierDigest, osMajor: 26, qualified: [classifier([27]), classifier([26])]) == true)
    // A future major without its own receipt downloads nothing (the quiet case this fix is for).
    #expect(CorrectionJudgeArmSelection.classifierIsQualifiedSomewhere(digest: Self.shippedClassifierDigest, osMajor: 28) == false)
    // Control: the same shipped digest on each covered major is qualified, so the 28 row above fails
    // for the major alone, not for the digest.
    for major in [14, 15, 26, 27] {
      #expect(CorrectionJudgeArmSelection.classifierIsQualifiedSomewhere(digest: Self.shippedClassifierDigest, osMajor: major) == true, "major \(major)")
    }
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
    let liveRules = RulesCorrectionJudge.configDigest(policy: .v2)
    let liveAFM = WordSuggestionService.correctionJudgeConfigDigest
    for entry in CorrectionJudgeArmSelection.qualified {
      switch entry.arm {
      case .rules: #expect(entry.configDigest == liveRules, "\(entry.receipt)")
      case .afm: #expect(entry.configDigest == liveAFM, "\(entry.receipt)")
      case .classifier:
        // The classifier's live digest exists only once the delivered model
        // has loaded; the table binds it to the exam receipt, and
        // `LearnFromEditsWiring` compares the two at publish time.
        #expect(entry.configDigest.count == 64, "\(entry.receipt)")
      }
      #expect(entry.osMajors.isEmpty == false)
      #expect(entry.receipt.isEmpty == false)
    }
  }
}
