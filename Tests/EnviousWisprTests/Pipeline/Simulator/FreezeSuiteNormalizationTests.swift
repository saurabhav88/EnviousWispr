import Foundation
import Testing

/// Freeze-suite normalization tests (epic #827, PR-2 plan §11.2 item G, §3.7).
/// Adversarial Unicode coverage — the normalization function gates lexical
/// parity, so a bug here either trips the freeze gate on a non-regression or
/// hides a real one.
@Suite("FreezeSuiteNormalization")
struct FreezeSuiteNormalizationTests {

  private func norm(_ s: String) -> String { FreezeSuiteNormalization.normalize(s) }

  @Test("rule 3 — casing is lowered")
  func casingLowered() {
    #expect(norm("Hello World") == "hello world")
  }

  @Test("rule 2 — whitespace runs collapse and ends trim")
  func whitespaceCollapsed() {
    #expect(norm("  hello   world  ") == "hello world")
    #expect(norm("hello\tworld") == "hello world")
  }

  @Test("rule 2 — non-breaking and zero-width spaces normalize")
  func unicodeWhitespaceNormalized() {
    #expect(norm("hello\u{00A0}world") == "hello world", "NBSP")
    #expect(norm("hello\u{200B}world") == "hello world", "zero-width space")
  }

  @Test("rule 6 — a single trailing period is stripped, internal periods kept")
  func trailingPeriodStripped() {
    #expect(norm("hello world.") == "hello world")
    #expect(norm("u.s. army") == "u.s. army", "internal periods are lexical")
  }

  @Test("rule 6 — a trailing run of terminal punctuation is stripped")
  func trailingRunStripped() {
    #expect(norm("hello...") == "hello")
    #expect(norm("hello!?") == "hello")
    #expect(norm("hello\u{2026}") == "hello", "ellipsis character")
  }

  @Test("rule 4 — curly apostrophes normalize to straight and are KEPT")
  func curlyApostropheKept() {
    #expect(norm("can\u{2019}t") == "can't")
    #expect(norm("can't") != "cant", "apostrophe is a word character — must be kept")
  }

  @Test("rule 5 — quote marks are stripped, not the apostrophes")
  func quoteMarksStripped() {
    #expect(norm("\"hello\"") == "hello")
    #expect(norm("\u{201C}hello\u{201D}") == "hello", "curly double quotes")
  }

  @Test("rule 7 — parentheses, brackets, slashes, commas strip")
  func otherPunctuationStripped() {
    #expect(norm("hello (world)") == "hello world")
    #expect(norm("a/b") == "ab")
    #expect(norm("one, two; three") == "one two three")
  }

  @Test("internal hyphens are kept — they are lexical")
  func internalHyphenKept() {
    #expect(norm("sub-second latency") == "sub-second latency")
  }

  @Test("rule 1 — NFC-decomposed and composed forms normalize equal")
  func nfcNormalization() {
    let composed = "café"  // single é
    let decomposed = "cafe\u{0301}"  // e + combining acute
    // Compare unicode SCALARS, not String ==. Swift String equality is
    // canonical-equivalence-aware, so `decomposed == composed` (and
    // `norm(composed) == norm(decomposed)`) are already true WITHOUT any
    // normalization — a String-level assert here passes even if `normalize`
    // were a no-op. Scalar comparison exposes whether NFC actually composed it.
    #expect(
      Array(norm(decomposed).unicodeScalars) == Array(composed.unicodeScalars),
      "decomposed e-acute must normalize to the NFC composed scalar (#860)")
    #expect(
      norm(decomposed).unicodeScalars.count == 4,
      "NFC-composed café is 4 scalars (c,a,f,é); a no-op normalize would leave 5")
  }

  @Test("em / en dashes between words survive as separators")
  func dashHandling() {
    // Dashes are not in the stripped set; they survive verbatim, and the single
    // spaces around them collapse to exactly one space each. #881 TO-4: pin the
    // exact form (like the 18 sibling `norm(...) == ...` asserts) instead of the
    // old `.contains("a")` / `.contains("b")`, which stayed green if the dash
    // were dropped ("a b"), remapped ("a-b"), or whitespace-mangled ("a  —  b").
    // Also exercise the EN dash (U+2013) the test name promises — the old body
    // never touched it.
    #expect(norm("a — b") == "a — b")  // em dash U+2014
    #expect(norm("a \u{2013} b") == "a \u{2013} b")  // en dash U+2013
  }
}
