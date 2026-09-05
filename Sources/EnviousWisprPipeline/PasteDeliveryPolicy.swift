import Foundation

/// Which delivery policy the cascade is running under (#2652).
///
/// **Why this type exists.** A reporter's dictation arrived TWICE in Safari page
/// textareas and a WebKit-backed compose window, proven by exact character counts, and
/// the defect does not reproduce on our hardware. Rather than argue a fix from a
/// mechanism story, we measure: run the candidate policies against real applications
/// and pick the one that delivers correctly in the widest set. This is the switch that
/// bake-off forces.
///
/// **Everything except `.current` is DEBUG-only, and release is a literal V0.** No user
/// ever runs a non-baseline policy; the release build's routing and its `app.log`
/// format are byte-identical to what shipped before this type existed.
///
/// **The initializer validates rather than trusts.** A test seam on a delivery guard is
/// a bypass unless it is logged AND unforgeable, and the specific way this one could
/// have lied is subtle: the harness stamps `variant=V2` on every scored row, so a
/// `writer`/`timeout`/`id` triple that disagrees with itself would produce a scorecard
/// full of confident rows describing a policy that never ran. The `precondition` makes
/// that combination unrepresentable instead of asking a reviewer to notice it.
/// (`validation-discipline.md` RULE: a-test-seam-on-a-GUARD-is-a-bypass-unless-it-is-logged.)
package struct PasteDeliveryPolicy: Sendable, Equatable {

  /// Which writer policy the cascade applies.
  ///
  /// `.current` is the only case that exists in a release build. The other two are
  /// compiled out entirely, so the release binary contains neither their behaviour nor
  /// their raw values for an artifact scan to find.
  package enum WriterPolicy: String, Sendable, Equatable {
    /// Today's cascade, unchanged. The baseline every measurement is relative to.
    case current

    #if DEBUG
      /// Skip Tier 1 when the target is POSITIVELY inside web content, and start at the
      /// existing key-paste route. Native chrome — a browser address bar included — and
      /// an ancestry we could not read both keep `.current` behaviour, so this arm tests
      /// web content rather than AX uncertainty in general.
      case webCmdV

      /// Tier 1 stays exactly as eligible as it is today, but once
      /// `AXUIElementSetAttributeValue` has RETURNED SUCCESS, no later automatic writer
      /// runs whatever the verification says. Declines before the write, and a write
      /// call that returns failure, still permit the fallback: nothing was mutated in
      /// either case. This is the strongest test of the coverage concern, because a
      /// destination that genuinely accepts the write and genuinely does nothing loses
      /// its automatic delivery here.
      case axOneWriter

      /// Deliberately deliver TWICE: after a successful key paste, paste once more.
      ///
      /// This arm exists to ARM the copies detector, not to test a candidate fix. A
      /// detector that has never seen the thing it detects is a comment: every Mac we
      /// own produces exactly one copy, so "it reported `once` on 300 dictations" is
      /// equally consistent with a working detector and with one wired to a constant.
      /// V6 stages the defect on purpose so the detector has a positive control.
      ///
      /// Never eligible in a release build, and never proposed as a fix.
      case deliberateDouble
    #endif
  }

  package let writer: WriterPolicy

  /// Whether to bound the Tier 1 element's own AX round trips with
  /// `AXUIElementSetMessagingTimeout`.
  ///
  /// We already set a messaging timeout for app-scoped focused-element reads and menu
  /// probing; what we have never done is apply one to the captured Tier 1 element
  /// before its read/write/read sequence — the one place the stale-read hazard lives.
  /// Three of the four competitors that attempt a direct write import this call.
  /// It bounds how long a single AX call may take. It does NOT make a destination's
  /// state settle sooner, and this arm exists to measure whether that distinction
  /// matters here rather than to assume it does.
  package let boundTier1MessagingTimeout: Bool

  /// The pre-declared variant label, stamped on every bake-off log line.
  package let id: String

  package init(writer: WriterPolicy, boundTier1MessagingTimeout: Bool, id: String) {
    #if DEBUG
      let valid =
        switch id {
        case "V0": writer == .current && !boundTier1MessagingTimeout
        case "V1": writer == .webCmdV && !boundTier1MessagingTimeout
        case "V2": writer == .axOneWriter && !boundTier1MessagingTimeout
        case "V4": writer == .current && boundTier1MessagingTimeout
        case "V5": writer == .webCmdV && boundTier1MessagingTimeout
        case "V6": writer == .deliberateDouble && !boundTier1MessagingTimeout
        default: false
        }
    #else
      let valid = writer == .current && !boundTier1MessagingTimeout && id == "V0"
    #endif
    precondition(valid, "Invalid paste-delivery policy combination: \(writer.rawValue)/\(id)")
    self.writer = writer
    self.boundTier1MessagingTimeout = boundTier1MessagingTimeout
    self.id = id
  }

  /// The shipped policy. The only one a release build can construct.
  package static let baseline = PasteDeliveryPolicy(
    writer: .current, boundTier1MessagingTimeout: false, id: "V0")

  /// True when this policy is the shipped baseline, so logging and routing can skip
  /// every bake-off branch without asking about each field separately.
  package var isBaseline: Bool { self == .baseline }

  #if DEBUG
    /// Environment variable naming the variant to force. DEBUG-only by construction:
    /// this string does not exist in a release binary, which the artifact scan asserts.
    package static let variantEnvironmentKey = "EW_PASTE_BAKEOFF_VARIANT"

    /// Environment variable carrying the harness's run identity. A non-baseline run
    /// without one is refused, so no scored row can be orphaned from the run that
    /// produced it.
    package static let runIDEnvironmentKey = "EW_PASTE_BAKEOFF_RUN_ID"

    /// Resolve the forced policy from an environment snapshot.
    ///
    /// **Fails closed to the baseline on every uncertainty**, and says so out loud: an
    /// unknown label, a missing run id, or an id whose combination does not validate all
    /// return `(baseline, nil)` with a rejection reason. A bake-off that silently ran the
    /// baseline while the harness believed otherwise is the one failure this whole type
    /// exists to prevent, so the caller MUST log `rejection` when it is non-nil.
    package static func resolve(
      environment: [String: String]
    ) -> (policy: PasteDeliveryPolicy, runID: String?, rejection: String?) {
      guard let raw = environment[variantEnvironmentKey], !raw.isEmpty else {
        return (.baseline, nil, nil)
      }
      guard let runID = environment[runIDEnvironmentKey], !runID.isEmpty else {
        return (.baseline, nil, "variant \(raw) refused: no \(runIDEnvironmentKey)")
      }
      let combination: (WriterPolicy, Bool)? =
        switch raw {
        case "V0": (.current, false)
        case "V1": (.webCmdV, false)
        case "V2": (.axOneWriter, false)
        case "V4": (.current, true)
        case "V5": (.webCmdV, true)
        case "V6": (.deliberateDouble, false)
        default: nil
        }
      guard let combination else {
        return (.baseline, nil, "variant \(raw) refused: not a declared variant")
      }
      return (
        PasteDeliveryPolicy(
          writer: combination.0, boundTier1MessagingTimeout: combination.1, id: raw),
        runID, nil
      )
    }
  #endif
}
