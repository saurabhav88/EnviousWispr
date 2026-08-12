import EnviousWisprCore
import Foundation
import NaturalLanguage

/// Decides what language a finished dictation is in, for consumers that must not
/// act on a guess (#1785, #1921).
///
/// The cursor-insertion repair only recases text in a language whose rules it
/// knows, so a WRONG language is worse than no language: it lowercases a
/// correctly capitalised German noun. This resolves the question from positive
/// evidence and abstains when there is none.
///
/// Written because the obvious source is not evidence. `ParakeetBackend` USED TO
/// stamp `language: "en"` on EVERY result, while the settings screen advertised
/// "Parakeet's 25 European languages, not just English" — and Parakeet is the
/// default engine. Reading that field directly meant a German dictation on the
/// default path was recased with English rules (cloud review, PR #1802).
///
/// #1678 removed that constant: Parakeet now reports `nil`, because it performs
/// no language detection and a user's lock is intent rather than a measurement.
/// **The precedence rule below is unchanged and still load-bearing** — it keys
/// on `engineDetectsLanguage`, not on the field's value, so it refuses a
/// non-detecting engine's answer whatever that answer is. That is exactly why
/// nil was the right replacement rather than writing the locked code here.
///
/// #1921 replaced a LENGTH floor with a CONFIDENCE floor. The old rule demanded
/// 24 alphabetic scalars before it would look at the recogniser's answer at all,
/// which refused **29.9% of 12,150 real continuations** — the short mid-sentence
/// insertions this feature exists for. The recogniser can identify far shorter
/// text than that; it was simply never asked how sure it was. Measured:
/// `Rat war gut.` (9 scalars) is German at 1.000, `On my way.` (7) is English at
/// 0.966, and across 33 deliberately adversarial non-English negatives the
/// highest ENGLISH score was 0.204. Receipts:
/// `docs/feature-requests/issue-1921-artifacts/`.
package enum DictationLanguageResolver {

  /// How sure the recogniser must be before its answer is used.
  ///
  /// 0.90 rather than a value closer to the observed noise floor, deliberately.
  /// These are not demonstrated calibrated probabilities, and the adversarial
  /// corpus was written by the same person choosing this number, so "headroom
  /// over my own worst case" is close to circular reasoning. 0.90 costs 3.8
  /// points of acceptance against 0.80 and still moves the feature from 70.0% to
  /// 87.6% of real continuations. Lower it only against an independently sourced
  /// multilingual corpus.
  package static let minConfidence = 0.90

  /// What the resolver decided, and on what evidence.
  ///
  /// `language` alone cannot say whether it came from the user's setting, the
  /// engine, the text, or nothing — so a field regression would be invisible.
  /// `Sendable` because this value is carried across the repair deadline's
  /// isolation boundary.
  package struct Resolution: Sendable {

    /// Which rung of the precedence ladder answered.
    package enum Source: String, Sendable {
      case locked, engine, dictation, document, none
    }

    /// Bucketed confidence. Buckets, never the raw score: the operational
    /// question is "did the gate start resolving", and a raw float per dictation
    /// is more precision than that needs.
    package enum Bucket: String, Sendable {
      case none, lt50, f50to70, f70to90, ge90

      init(_ confidence: Double) {
        // A non-finite score falls to `none` rather than through the range
        // ladder. NaN compares false against every bound, so it would otherwise
        // reach `default` and be reported as the HIGHEST bucket — a telemetry
        // value that says "very confident" about an answer the gate refused,
        // since NaN also fails `>= minConfidence`.
        guard confidence.isFinite else {
          self = .none
          return
        }
        switch confidence {
        case ..<0.50: self = .lt50
        case ..<0.70: self = .f50to70
        case ..<0.90: self = .f70to90
        default: self = .ge90
        }
      }
    }

    let language: String?
    let source: Source
    let confidenceBucket: Bucket
  }

  /// What the recogniser thinks, and how sure it is. No policy.
  ///
  /// Deliberately sets NO `languageConstraints`. Constraining to the default
  /// engine's own language list looks obviously right and is not: every
  /// non-Latin script then returns nil, which collapses Japanese, Chinese and
  /// Thai to `LanguageRules.unknown`, whose `usesWordSpacing` is true — so the
  /// repair would ADD spaces those languages must not have, on BOTH sides:
  /// rule 1 (`CursorInsertionRepair.swift:392`) adds the leading one and rule 3
  /// (`:487`) the trailing one, and both read that same field. Measured both
  /// ways; unconstrained also decouples this from which engine ran.
  package static func identify(_ text: String) -> (language: String, confidence: Double)? {
    guard !text.isEmpty else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard
      let top = recognizer.languageHypotheses(withMaximum: 3)
        .max(by: { $0.value < $1.value }),
      let base = LanguageNormalizer.baseCode(top.key.rawValue)
    else { return nil }
    return (base, top.value)
  }

  /// The dictation's language, or an unresolved answer when nothing establishes it.
  ///
  /// Precedence, strongest evidence first:
  /// 1. **The user told us.** A locked language outranks anything inferred.
  /// 2. **An engine that actually detects.** Only when the engine reports
  ///    `supportsLanguageDetection`; an engine that hard-codes a language is
  ///    reporting a constant, not a detection.
  /// 3. **The text itself**, at or above `minConfidence`. This is the default
  ///    engine's normal path.
  /// 4. **The surrounding document, as a VETO only.**
  ///
  /// - Parameter identify: seam. Real recogniser output cannot reproducibly hit
  ///   0.899 / 0.900 / 0.901 across OS versions, so the boundary is tested
  ///   through this rather than by hunting for input that happens to land there.
  package static func resolve(
    lockedLanguage: String?,
    engineDetectsLanguage: Bool,
    engineReportedLanguage: String?,
    text: String,
    surroundingText: String = "",
    identify: (String) -> (language: String, confidence: Double)? = Self.identify
  ) -> Resolution {
    if let lockedLanguage, !lockedLanguage.isEmpty {
      return Resolution(language: lockedLanguage, source: .locked, confidenceBucket: .none)
    }
    if engineDetectsLanguage, let engineReportedLanguage, !engineReportedLanguage.isEmpty {
      return Resolution(language: engineReportedLanguage, source: .engine, confidenceBucket: .none)
    }

    // `isFinite` at every acceptance gate, not only in the bucket. Infinity
    // satisfies `>= minConfidence` while bucketing to `none`, which would resolve
    // a language while reporting no confidence — a contradiction the field could
    // never explain. Hypothetical from the real recogniser, reachable through the
    // seam, and silent if wrong, which is the shape worth guarding.
    let fromDictation = identify(text).flatMap { $0.confidence.isFinite ? $0 : nil }
    let dictationBucket = fromDictation.map { Resolution.Bucket($0.confidence) } ?? .none
    if let fromDictation, fromDictation.confidence >= minConfidence {
      return Resolution(
        language: fromDictation.language, source: .dictation, confidenceBucket: dictationBucket)
    }

    // The surrounding document may VETO, never authorise.
    //
    // An earlier version let the document decide outright, under a comment
    // claiming both mixed cases were safe. That was false in one direction: an
    // English document with a short GERMAN insertion resolves to English, and
    // English casing then lowercases a German noun — the precise defect this
    // path exists to prevent (cloud review, PR #1802). Re-measured for #1921:
    // 17 of 24 German nouns that are also English words would have been
    // wrongly lowered, and the word-level oracle stops only 7 of them.
    //
    // So the document can only ever make us MORE conservative. If it reads as a
    // language we do not case, we take that and skip casing. If it reads as
    // English we still abstain, because the insertion itself was never
    // identified and English is the one answer that lets recasing proceed.
    guard !surroundingText.isEmpty,
      let fromDocument = identify(surroundingText + " " + text),
      fromDocument.confidence.isFinite,
      fromDocument.confidence >= minConfidence,
      fromDocument.language != "en"
    else {
      return Resolution(language: nil, source: .none, confidenceBucket: dictationBucket)
    }
    return Resolution(
      language: fromDocument.language,
      source: .document,
      confidenceBucket: Resolution.Bucket(fromDocument.confidence))
  }
}
