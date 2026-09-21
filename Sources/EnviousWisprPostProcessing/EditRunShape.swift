import Foundation

// MARK: - Stage-1 shape of an edited run (#996, plan §3.1 step 5)
//
// Alignment drops casing-only and punctuation-only runs before any judge is
// asked (frozen convention: casing-only is notCorrection). The check lives
// here, once, so `EditAlignment` (chunk 4c-i) and the eval runner apply the
// same rule: what the exam measures is the shipped path, alignment then
// judge, never the judge on rows the product would have dropped.
package enum EditRunShape {
  /// True when `original` and `replacement` differ only in letter case,
  /// punctuation or symbols, with the same word count: "monday" → "Monday",
  /// "its" → "it's", "hello" → "hello!". A join or split ("post hog" →
  /// "PostHog", "e mail" → "e-mail") changes the word count and is NOT
  /// shape-dropped: the judge decides those.
  package static func isCasingOrPunctuationOnly(original: String, replacement: String) -> Bool {
    let o = words(original)
    let r = words(replacement)
    guard !o.isEmpty, o.count == r.count else { return false }
    guard original.precomposedStringWithCanonicalMapping != replacement.precomposedStringWithCanonicalMapping
    else { return false }
    return zip(o, r).allSatisfy { $0 == $1 }
  }

  /// Words as letters-and-digits only, NFC, casefolded: everything the
  /// shape rule ignores is removed before comparison.
  private static func words(_ text: String) -> [String] {
    text.precomposedStringWithCanonicalMapping
      .split(whereSeparator: \.isWhitespace)
      .map { String($0.filter { $0.isLetter || $0.isNumber }).lowercased() }
      .filter { !$0.isEmpty }
  }
}
