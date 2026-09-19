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

  /// The measured table. EMPTY until chunk 4a's frozen reports are scored;
  /// an empty table selects nothing anywhere, which is the honest state of
  /// a build that has not been measured.
  package static let qualified: [CorrectionJudgeQualification] = []

  /// Step 7, verbatim: below the AFM floor, qualified rules serve or nothing
  /// does; at and above it, qualified and available AFM serves, otherwise
  /// independently qualified rules, otherwise nothing.
  package static func select(
    osMajor: Int, afmAvailable: Bool, rulesDigest: String, afmDigest: String?,
    qualified: [CorrectionJudgeQualification] = qualified
  ) -> CorrectionJudgeArmSelection {
    func isQualified(_ arm: CorrectionJudgeArm, digest: String?) -> Bool {
      guard let digest else { return false }
      return qualified.contains {
        $0.arm == arm && $0.osMajors.contains(osMajor) && $0.configDigest == digest
      }
    }
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
