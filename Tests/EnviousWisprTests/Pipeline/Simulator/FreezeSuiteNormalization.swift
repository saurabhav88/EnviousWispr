import Foundation

// MARK: - Freeze-suite normalization (epic #827, PR-2 plan §3.7; epic §11.2)
//
// The freeze gate compares LEXICAL parity — words, not punctuation formatting.
// Both `rawTranscript` and `normalizedTranscript` are committed to
// `baseline.json` so punctuation deltas stay auditable even though they do not
// gate. This function is applied identically to the old-path baseline and the
// new-path output.
//
// Eight rules, in order (PR-2 plan §3.7). Itself unit-tested with adversarial
// Unicode cases in `FreezeSuiteNormalizationTests`.

enum FreezeSuiteNormalization {

  /// Ruleset version — the identity of the eight normalization rules below.
  /// `baseline.json` records this integer; PR-4/PR-5's freeze-suite comparison
  /// refuses to run against a baseline whose recorded `normalization_ruleset_version`
  /// differs from this constant, forcing a deliberate re-capture rather than a
  /// silent semantic drift (PR-3 plan §3.8). Bump whenever a rule changes.
  static let rulesetVersion = 1

  /// Curly / typographic apostrophes normalized to straight `'` and KEPT —
  /// they are word characters (`can't` ≠ `cant` is a real regression).
  private static let apostropheVariants: [Character] = ["\u{2019}", "\u{2018}", "\u{02BC}"]

  /// Quote MARKS — stripped (distinct from the apostrophes above).
  private static let quoteMarks: [Character] = [
    "\"", "\u{201C}", "\u{201D}", "\u{00AB}", "\u{00BB}",
  ]

  /// Non-terminal punctuation stripped globally. Internal `.!?` are NOT here —
  /// only a TRAILING run of those is stripped (rule 6). Internal hyphens are
  /// kept (lexical).
  private static let strippedPunctuation: Set<Character> = [
    ",", ";", ":", "(", ")", "[", "]", "{", "}", "/",
  ]

  /// A trailing run of these is stripped (rule 6).
  private static let terminalPunctuation: Set<Character> = [".", "!", "?", "\u{2026}"]

  /// Normalize `input` for lexical-parity comparison (PR-2 plan §3.7).
  static func normalize(_ input: String) -> String {
    // Rule 1 — Unicode NFC normalize before any other rule.
    var text = input.precomposedStringWithCanonicalMapping

    // Rule 4 — curly apostrophes → straight, kept.
    for variant in apostropheVariants {
      text = text.replacingOccurrences(of: String(variant), with: "'")
    }

    // Rule 5 — strip quote marks (not the apostrophes from rule 4).
    text.removeAll { quoteMarks.contains($0) }

    // Rule 3 — lowercase.
    text = text.lowercased()

    // Rule 7 — strip non-terminal punctuation.
    text.removeAll { strippedPunctuation.contains($0) }

    // Rule 2 — every Unicode whitespace class → ASCII space, collapse runs,
    // trim. Splitting on the Unicode whitespace property handles NBSP,
    // zero-width and other classes a naive ` ` split would miss.
    let collapsed = text.unicodeScalars
      .split { $0.properties.isWhitespace || $0 == "\u{200B}" }
      .map { String(String.UnicodeScalarView($0)) }
      .joined(separator: " ")

    // Rule 6 — strip a trailing run of terminal punctuation, then re-trim.
    var result = Substring(collapsed)
    while let last = result.last, terminalPunctuation.contains(last) {
      result = result.dropLast()
    }
    return String(result).trimmingCharacters(in: .whitespaces)
  }
}
