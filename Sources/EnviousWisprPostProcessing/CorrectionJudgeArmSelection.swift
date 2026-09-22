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
  /// the honest state of a build that has not been measured. Phase D
  /// (2026-09-21): the bundled delivery manifest names the fp16 package
  /// `3b376fbc-ec68ad6e` (mmbert-v15 exported under the half-precision
  /// decision-parity bar: zero decision flips on every compute unit, logit
  /// drift reported, `convert_edit_judge.VARIANT_LOGIT_TOLERANCE`). The
  /// digest is the loader's composite classifier identity, equal to the
  /// manifest's `runtimeIdentityDigest` (`EditJudgeManifestTests` pins the
  /// equality), so every row names the exact examined bytes. One row per
  /// macOS major, each with its own exam v2 receipt (frozen under
  /// `artifacts/issue-996-edit-judge/frozen/`, host recorded in
  /// `scorecard.json["host"]`):
  ///
  /// - macOS 27, the founder's M4 Pro, Neural Engine: PASS, correction
  ///   recall 1012/1064 = 0.951, false-proposal rate 18/2498 = 0.0072, every
  ///   per-kind guardrail met, latency p50 3.1 ms.
  /// - macOS 26 and macOS 15, hosted GitHub runners (`Apple M1 (Virtual)`,
  ///   `virtual: true`, CPU path; virtual Macs expose no Neural Engine):
  ///   PASS, identical decisions on both, recall 1012/1064, false 19/2498 =
  ///   0.0076 (one more than the Neural Engine run, the same count as the
  ///   fp32 twin), every guardrail met, p50 13.7 ms (26) and 102 ms (15) on
  ///   a virtual M1 CPU.
  /// - macOS 14 (14.8.9), an AWS EC2 mac2.metal dedicated host: bare-metal
  ///   Apple M1 Mac mini, `virtual: false`, Neural Engine present (probe:
  ///   839 ops placed on the Neural Engine, parity with the CPU path): PASS,
  ///   recall 1012/1064 = 0.951, false 18/2498 = 0.0072 (the macOS 27
  ///   count), every guardrail met, p50 4.96 ms.
  ///
  /// Founder decision 2026-09-21: macOS 15 and 26 are qualified on their
  /// own CPU receipts; the floor (14) and the top (27) supply the two
  /// Neural Engine receipts on real hardware. The residual risk is a Neural
  /// Engine compiler or placement defect specific to 15 or 26. Existing
  /// telemetry reports load, execution and bypass failures, but cannot
  /// identify a valid-looking wrong decision as a compiler defect.
  package static let qualified: [CorrectionJudgeQualification] = [
    CorrectionJudgeQualification(
      arm: .classifier, osMajors: [27],
      configDigest: "eb570c8044d8a769e4719a429560430cd96be204759fe3c783fde80b5468038d",
      receipt: "2026-09-21T13-22-50Z-xenc-mmbert-small-exam-v2"),
    CorrectionJudgeQualification(
      arm: .classifier, osMajors: [26],
      configDigest: "eb570c8044d8a769e4719a429560430cd96be204759fe3c783fde80b5468038d",
      receipt: "2026-09-21T18-34-51Z-xenc-mmbert-small-exam-v2-macos26"),
    CorrectionJudgeQualification(
      arm: .classifier, osMajors: [15],
      configDigest: "eb570c8044d8a769e4719a429560430cd96be204759fe3c783fde80b5468038d",
      receipt: "2026-09-21T18-34-55Z-xenc-mmbert-small-exam-v2-macos15"),
    CorrectionJudgeQualification(
      arm: .classifier, osMajors: [14],
      configDigest: "eb570c8044d8a769e4719a429560430cd96be204759fe3c783fde80b5468038d",
      receipt: "2026-09-22T02-18-33Z-xenc-mmbert-small-exam-v2-macos14"),
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
