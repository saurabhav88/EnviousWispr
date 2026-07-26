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
  static func resolve(
    lockedLanguage: String?,
    engineDetectsLanguage: Bool,
    engineReportedLanguage: String?,
    text: String
  ) -> String? {
    if let lockedLanguage, !lockedLanguage.isEmpty { return lockedLanguage }
    if engineDetectsLanguage, let engineReportedLanguage, !engineReportedLanguage.isEmpty {
      return engineReportedLanguage
    }
    return dominantLanguage(of: text)
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
