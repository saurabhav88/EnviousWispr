import Foundation

extension InverseTextNormalizer {

  /// The language route's text execution (#1677): what runs on a take whose language HAS a vetted
  /// rule set.
  ///
  /// Today that is the language-neutral subset followed by ZERO language passes, so the result is
  /// byte-identical to `normalizeLanguageNeutral`. Language passes arrive with the generator PR and
  /// run after the neutral subset, refusing any span a neutral pass already wrote.
  ///
  /// **Never calls the English `normalize`.** English number words collide with other languages
  /// (`ten` is a Polish demonstrative, German `am` is not the meridiem), so this entry must not
  /// reach the English lexicon.
  ///
  /// Takes the immutable rule-set SNAPSHOT, not a language code: nothing here rereads a registry.
  package func normalize(_ text: String, language ruleSet: LanguageRuleSet) -> String {
    _ = ruleSet  // no language passes yet; the parameter fixes the contract the passes will use
    return normalizeLanguageNeutral(text)
  }
}
