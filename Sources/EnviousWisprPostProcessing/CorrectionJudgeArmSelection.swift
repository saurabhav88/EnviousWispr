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

  /// The measured table. An empty table selects nothing anywhere, which is
  /// the honest state of a build that has not been measured. #3105
  /// (2026-09-26): the bundled delivery manifest names Judge 1 v31,
  /// `dbc928ac-668f45b8` (the spelled-input mmBERT, fp16; the app builds the
  /// pair from the export's `decision_config.encoding.pair_input`). The digest
  /// is the loader's composite classifier identity, equal to the manifest's
  /// `runtimeIdentityDigest` (`EditJudgeManifestTests` pins the equality), so
  /// every row names the exact delivered bytes.
  ///
  /// v31 ships on founder decisions, not on the exam v2 bar (it misses the 2%
  /// false-proposal bar by design):
  /// - Quality: founder 2026-09-25 "ship it" (#3105 comment 5839274370) at the
  ///   85% recall point on the fresh real-speech bench; the waiver is recorded
  ///   in the export's `thresholds.waiver` (tune half: recall 954/1122 = 0.850,
  ///   false 195/3848 = 0.051 at threshold 0.680). Exam v2 is the wrong
  ///   population for this model (plan issue-3105-2026-09-25 P3).
  /// - macOS 27: the conversion receipt on the founder's Mac (every Core ML
  ///   placement, Neural Engine included: 0 decision flips over 73 rows
  ///   against the trained model), frozen under
  ///   `artifacts/issue-996-edit-judge/frozen/2026-09-25T23-25-51Z-xenc-mmbert-small-v31-spell-fp16-conversion-macos27/`.
  /// - macOS 14, 15 and 26: founder 2026-09-26, "No need to test the judge on
  ///   older versions". No run on those majors; the residual risk is a Core ML
  ///   compiler or placement difference specific to one of them, which load,
  ///   execution and bypass telemetry can report but a valid-looking wrong
  ///   decision cannot.
  /// The v15 rows (`eb570c80…`) are gone with the v15 manifest: a digest the
  /// manifest no longer names can never serve.
  package static let qualified: [CorrectionJudgeQualification] = [
    CorrectionJudgeQualification(
      arm: .classifier, osMajors: [27],
      configDigest: "73d1c5147945dff0b7aa8ba0bd5de8669750955eaf4f51895c1741b4575adb2a",
      receipt: "2026-09-25T23-25-51Z-xenc-mmbert-small-v31-spell-fp16-conversion-macos27"),
    CorrectionJudgeQualification(
      arm: .classifier, osMajors: [26],
      configDigest: "73d1c5147945dff0b7aa8ba0bd5de8669750955eaf4f51895c1741b4575adb2a",
      receipt: "founder-2026-09-26-no-older-macos-runs-v31-macos26"),
    CorrectionJudgeQualification(
      arm: .classifier, osMajors: [15],
      configDigest: "73d1c5147945dff0b7aa8ba0bd5de8669750955eaf4f51895c1741b4575adb2a",
      receipt: "founder-2026-09-26-no-older-macos-runs-v31-macos15"),
    CorrectionJudgeQualification(
      arm: .classifier, osMajors: [14],
      configDigest: "73d1c5147945dff0b7aa8ba0bd5de8669750955eaf4f51895c1741b4575adb2a",
      receipt: "founder-2026-09-26-no-older-macos-runs-v31-macos14"),
  ]

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
