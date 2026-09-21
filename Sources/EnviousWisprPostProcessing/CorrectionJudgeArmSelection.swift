import EnviousWisprCore
import Foundation

// MARK: - Which correction-judge arm serves on this Mac (#996, plan §3.1 step 7)
//
// The ONE runtime authority for arm selection: the watcher asks it which
// judge to run and the Settings row asks it what to say. Three things are all
// required before an arm serves: the platform can run it, it was MEASURED
// to qualify on the frozen report set (§3a) under the exact configuration
// this build ships, and it is available right now. Framework presence is
// never qualification: an AFM that compiles and is switched on still does
// not serve until a frozen report under this build's prompt digest says so.
//
// `qualified` is written from receipts, never from expectation. Each entry
// binds an arm, the macOS majors it was measured for and the configuration
// digest of the run; `select` honours an entry only when the digest matches
// the arm's live digest, so changing a rule or a prompt silently REVOKES
// qualification until the report is run again. A failed or unmeasured
// configuration simply has no entry.
package enum CorrectionJudgeArm: String, Sendable, CaseIterable, Equatable {
  /// `RulesCorrectionJudge`: every supported macOS.
  case rules
  /// `WordSuggestionService` through FoundationModels: macOS 26 and later.
  case afm
  /// `CoreMLCorrectionJudge`, the delivered cross-encoder (#996 phase D):
  /// every supported macOS the delivered package was examined on. Its
  /// qualification digest is the loader's composite classifier identity
  /// (package, tokenizer and decision configuration), never the package alone.
  case classifier
}

package struct CorrectionJudgeQualification: Sendable, Equatable {
  package let arm: CorrectionJudgeArm
  /// macOS majors the frozen report covers for this arm. A report on
  /// macOS 27 says nothing about 26; each measured major is listed.
  package let osMajors: Set<Int>
  /// `config_sha256` of the execution identity the report was scored under.
  package let configDigest: String
  /// Where the evidence lives (frozen run id under
  /// `artifacts/issue-996-edit-judge/frozen/`), for the reader, never read
  /// at runtime.
  package let receipt: String

  package init(arm: CorrectionJudgeArm, osMajors: Set<Int>, configDigest: String, receipt: String) {
    self.arm = arm
    self.osMajors = osMajors
    self.configDigest = configDigest
    self.receipt = receipt
  }
}

package enum CorrectionJudgeArmSelection: Sendable, Equatable {
  case arm(CorrectionJudgeArm)
  /// No arm may serve. `reason` is a closed set for telemetry and copy.
  case unavailable(Reason)

  package enum Reason: String, Sendable, Equatable, CaseIterable {
    /// Nothing is qualified for this macOS major under this build.
    case noQualifiedArm
    /// AFM is qualified here but switched off or not yet ready, and rules
    /// are not independently qualified for this major.
    case afmUnavailableNoRulesFallback
  }

  /// FoundationModels' platform floor. Below it AFM is never considered.
  package static let afmFloorMajor = 26

  /// The measured table. EMPTY until a frozen report qualifies an arm; an
  /// empty table selects nothing anywhere, which is the honest state of a
  /// build that has not been measured. Phase D (2026-09-21): the bundled
  /// delivery manifest names the fp16 package `3b376fbc-4962ff76`, which is
  /// STAGED, NOT QUALIFIED: its conversion misses the converter's 1e-2 logit
  /// bar and the exam gate refuses to examine it until the founder sets the
  /// half-precision bar. No classifier entry, therefore no automatic download
  /// (`EditJudgeFetchPolicy` requires one) and no judge; the entry is added
  /// with the exam receipt id and the loader's composite identity digest.
  package static let qualified: [CorrectionJudgeQualification] = []

  /// Whether this build qualifies THE classifier the bundled manifest names
  /// (its `runtimeIdentityDigest`) for ANY macOS: the fetch policy's first
  /// gate. A manifest can ship ahead of its receipt, and a receipt for an
  /// older package never licenses a newer one's download; bytes move only for
  /// a package some receipt names (round 16 finding 9).
  package static func classifierIsQualifiedSomewhere(
    digest: String?, qualified: [CorrectionJudgeQualification] = qualified
  ) -> Bool {
    guard let digest else { return false }
    return qualified.contains { $0.arm == .classifier && $0.configDigest == digest }
  }

  /// Step 7 with phase D's first rung: a LOADED classifier whose composite
  /// identity digest is qualified for this macOS serves before anything else
  /// (`classifierDigest` is nil until the delivered model has loaded, so an
  /// admitted-but-unloaded, failed, disabled or digest-mismatched classifier
  /// never serves). Then, verbatim: below the AFM floor, qualified rules serve
  /// or nothing does; at and above it, qualified and available AFM serves,
  /// otherwise independently qualified rules, otherwise nothing.
  package static func select(
    osMajor: Int, afmAvailable: Bool, rulesDigest: String, afmDigest: String?,
    classifierDigest: String? = nil,
    qualified: [CorrectionJudgeQualification] = qualified
  ) -> CorrectionJudgeArmSelection {
    func isQualified(_ arm: CorrectionJudgeArm, digest: String?) -> Bool {
      guard let digest else { return false }
      return qualified.contains {
        $0.arm == arm && $0.osMajors.contains(osMajor) && $0.configDigest == digest
      }
    }
    if isQualified(.classifier, digest: classifierDigest) { return .arm(.classifier) }
    let rulesQualified = isQualified(.rules, digest: rulesDigest)
    guard osMajor >= afmFloorMajor else {
      return rulesQualified ? .arm(.rules) : .unavailable(.noQualifiedArm)
    }
    let afmQualified = isQualified(.afm, digest: afmDigest)
    if afmQualified && afmAvailable { return .arm(.afm) }
    if rulesQualified { return .arm(.rules) }
    return .unavailable(afmQualified ? .afmUnavailableNoRulesFallback : .noQualifiedArm)
  }
}
