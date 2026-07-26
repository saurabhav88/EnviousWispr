import EnviousWisprCore
import Foundation
import NaturalLanguage

/// Decides what language a finished dictation is in, for consumers that must not
/// act on a guess (#1785).
///
/// The cursor-insertion repair only recases text in a language whose rules it
/// knows, so a WRONG language is worse than no language: it lowercases a
/// correctly capitalised German noun. This resolves the question from positive
/// evidence and abstains when there is none.
///
/// Written because the obvious source is not evidence. `ParakeetBackend` stamps
/// `language: "en"` on EVERY result, while the settings screen advertises
/// "Parakeet's 25 European languages, not just English" — and Parakeet is the
/// default engine. Reading that field directly meant a German dictation on the
/// default path was recased with English rules (cloud review, PR #1802).
enum DictationLanguageResolver {

  /// Minimum alphabetic scalars before `NLLanguageRecognizer` is trusted.
  /// Matches the existing precedent in the polish output validator: below this
  /// the recognizer's answer is noise, and a wrong answer here recases text.
  static let minAlphabeticScalars = 24

  /// The dictation's language, or nil when nothing can positively establish it.
  ///
  /// Precedence, strongest evidence first:
  /// 1. **The user told us.** A locked language setting is a statement of intent
  ///    and outranks anything inferred.
  /// 2. **An engine that actually detects.** Only meaningful when the engine
  ///    reports `supportsLanguageDetection`; an engine that hard-codes a
  ///    language is not reporting a detection, it is reporting a constant.
  /// 3. **The text itself.** Apple's recognizer, above a length floor, for
  ///    everything else — which is the default engine's normal path.
  ///
  /// Returns nil rather than a default. Callers must treat nil as "unknown" and
  /// do the conservative thing, not fall back to English.
  /// - Parameter surroundingText: the document text either side of the caret,
  ///   already read for the repair. Used ONLY when the dictation alone is too
  ///   short to identify, which is the common case for a mid-sentence
  ///   continuation: "Store is closed today" is 18 alphabetic scalars, under the
  ///   floor, so on the default engine the feature would never fire for exactly
  ///   the short insertions it was built for (cloud review, PR #1802).
  ///
  ///   Reading the surrounding document is safe in the direction that matters. A
  ///   German document with a German insertion identifies as German — correct. An
  ///   English document with an English insertion identifies as English —
  ///   correct. The mixed cases (dictating English into a German document, or
  ///   the reverse) identify as the document's language, so casing is SKIPPED,
  ///   which is today's behaviour rather than a wrong recasing.
  static func resolve(
    lockedLanguage: String?,
    engineDetectsLanguage: Bool,
    engineReportedLanguage: String?,
    text: String,
    surroundingText: String = ""
  ) -> String? {
    if let lockedLanguage, !lockedLanguage.isEmpty { return lockedLanguage }
    if engineDetectsLanguage, let engineReportedLanguage, !engineReportedLanguage.isEmpty {
      return engineReportedLanguage
    }
    if let fromDictation = dominantLanguage(of: text) { return fromDictation }
    // The surrounding document may VETO, never authorise.
    //
    // My first version let the document decide outright, under a comment
    // claiming both mixed cases were safe. That was false in one direction and I
    // did not check it: an English document with a short GERMAN insertion
    // resolves to English, and English casing then lowercases a German noun —
    // the precise defect this whole path exists to prevent (cloud review, PR
    // #1802, second time tonight a confident comment covered an unchecked claim).
    //
    // So the document can only ever make us MORE conservative. If it reads as a
    // language we do not case, we take that and skip casing. If it reads as
    // English we still abstain, because the insertion itself was never
    // identified and English is the one answer that lets recasing proceed.
    guard !surroundingText.isEmpty,
      let fromDocument = dominantLanguage(of: surroundingText + " " + text),
      fromDocument != "en"
    else { return nil }
    return fromDocument
  }

  /// Apple's on-device recognizer, or nil when the text is too short to trust or
  /// the recognizer will not commit.
  static func dominantLanguage(of text: String) -> String? {
    let letters = text.unicodeScalars.filter(\.properties.isAlphabetic).count
    guard letters >= minAlphabeticScalars else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let dominant = recognizer.dominantLanguage?.rawValue else { return nil }
    return LanguageNormalizer.baseCode(dominant)
  }
}
