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
  /// punctuation or symbols: "monday" → "Monday", "its" → "it's", "hello" →
  /// "hello!", and a join or split made with punctuation ("e mail" → "e-mail",
  /// "node js" → "node.js"). A join or split made only with spaces ("post
  /// hog" → "PostHog") is NOT shape-dropped: the judge decides those.
  package static func isCasingOrPunctuationOnly(original: String, replacement: String) -> Bool {
    if isPunctuatedJoinOrSplit(original: original, replacement: replacement) { return true }
    let o = words(original)
    let r = words(replacement)
    guard !o.isEmpty, o.count == r.count else { return false }
    guard
      original.precomposedStringWithCanonicalMapping
        != replacement.precomposedStringWithCanonicalMapping
    else { return false }
    return zip(o, r).allSatisfy { $0 == $1 }
  }

  /// #3258: a word-count-changing edit whose letters and digits are
  /// unchanged (casefolded) and which adds or removes punctuation or symbols,
  /// not only spaces ("Miami Illinois" → "Miami-Illinois"). Founder
  /// 2026-09-25: hyphen, apostrophe and punctuation-only edits never reach
  /// Judge 1; polish owns them. The shipped judge learned 40 of 367 such
  /// real-speech edits (night-0930 bench, tune half). Sentence decoration at
  /// token edges is ignored, so a compound joined across a recognised comma
  /// ("Satz, Bau" → "Satzbau") is a space-only join and still reaches the judge.
  static func isPunctuatedJoinOrSplit(original: String, replacement: String) -> Bool {
    let o = original.precomposedStringWithCanonicalMapping.lowercased()
    let r = replacement.precomposedStringWithCanonicalMapping.lowercased()
    guard
      o.split(whereSeparator: \.isWhitespace).count != r.split(whereSeparator: \.isWhitespace).count
    else { return false }
    let letters = { (s: String) in s.filter { $0.isLetter || $0.isNumber } }
    let marks = { (s: String) in
      s.split(whereSeparator: \.isWhitespace)
        .map { WordCorrector.stripPunctuationStatic(String($0)) }.joined()
    }
    return !letters(o).isEmpty && letters(o) == letters(r) && marks(o) != marks(r)
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
