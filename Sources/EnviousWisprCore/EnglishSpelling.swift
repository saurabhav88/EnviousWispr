import Foundation

/// Which spelling English dictation is delivered in (#3124).
///
/// A PREFERENCE, stored separately from `LanguageMode`, because the speech engines only ever
/// receive "en": Parakeet's language input is a script filter, WhisperKit's language tokens carry
/// no region, and the settings loader rejects a regional code. The picker's "English (UK)" row
/// sets `.british` together with `.locked("en")`.
public enum EnglishSpelling: String, Codable, Sendable, CaseIterable {
  case american
  case british

  /// Whether British spelling is IN FORCE for a take: only when the language is locked to English
  /// AND the stored preference is British. The one place this is decided; every later reader uses
  /// the value frozen from here. A preference left at `.british` while another language, or Auto,
  /// is selected has no effect.
  public static func effective(languageMode: LanguageMode, stored: EnglishSpelling)
    -> EnglishSpelling
  {
    guard stored == .british, case .locked(let code) = languageMode,
      LanguageNormalizer.baseCode(code) == "en"
    else { return .american }
    return .british
  }
}
