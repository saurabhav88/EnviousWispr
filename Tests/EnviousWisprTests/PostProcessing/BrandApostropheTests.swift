import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

/// #998 — brand canonicals restored to their correct apostrophe/accent spelling
/// in `brands.json`, with the plain (apostrophe-/accent-less) ASR form added as
/// an alias so the everyday spoken token still corrects to the proper glyphs.
///
/// These tests run against the REAL bundled brands pack (not a synthetic
/// fixture), so they lock both the shipped data and the corrector's paste path.
/// Adversarial per `matcher-set-adversarial-tests`: each new plain alias is
/// exercised in its intended class AND a non-intended (no-false-positive) class.
@Suite("Brand apostrophes/accents (#998)")
struct BrandApostropheTests {

  private func brandsPackTerms() -> [CustomWord] {
    guard let pack = VocabularyPackStore().load(.brands) else {
      Issue.record("brands pack failed to load from bundle")
      return []
    }
    return pack.terms
  }

  private func corrected(_ input: String, _ terms: [CustomWord]) -> String {
    WordCorrector().correct(input, against: terms).corrected
  }

  // MARK: Forward — plain ASR token corrects to the apostrophe'd/accented canonical

  @Test("apostrophe brands: plain spoken form corrects to the apostrophe'd canonical")
  func apostropheForward() {
    let terms = brandsPackTerms()
    let cases: [(String, String)] = [
      ("applebees", "Applebee's"),
      ("campbells", "Campbell's"),
      ("mcdonalds", "McDonald's"),
      ("wendys", "Wendy's"),
      ("reeses", "Reese's"),
      ("nathans", "Nathan's"),
    ]
    for (input, expected) in cases {
      #expect(
        corrected(input, terms) == expected,
        "'\(input)' should correct to '\(expected)', got '\(corrected(input, terms))'")
    }
  }

  /// Short brands (5-char cores) sit below `packFuzzyMinLength` (7), so the pack
  /// fuzzy tier is gated off and the plain alias is the ONLY path that can carry
  /// them. This proves the alias add is mandatory, not redundant with fuzzy.
  @Test("short brands (below fuzzy gate) correct only because the plain alias exists")
  func shortBrandMandatoryAlias() {
    let terms = brandsPackTerms()
    let cases: [(String, String)] = [
      ("arbys", "Arby's"),
      ("lowes", "Lowe's"),
      ("macys", "Macy's"),
      ("kohls", "Kohl's"),
      ("titos", "Tito's"),
    ]
    for (input, expected) in cases {
      #expect(
        corrected(input, terms) == expected,
        "'\(input)' should correct to '\(expected)', got '\(corrected(input, terms))'")
    }
  }

  @Test("accent brands: plain spoken form corrects to the accented canonical, glyphs intact")
  func accentForward() {
    let terms = brandsPackTerms()
    let cases: [(String, String)] = [
      ("loreal", "L'Oréal"),
      ("l'oreal", "L'Oréal"),  // real ASR rendering (apostrophe kept, accent dropped) — live-UAT verified
      ("kahlua", "Kahlúa"),
      ("mccafe", "McCafé"),
      ("citroen", "Citroën"),
      ("mondelez", "Mondelēz"),
    ]
    for (input, expected) in cases {
      let out = corrected(input, terms)
      #expect(out == expected, "'\(input)' should correct to '\(expected)', got '\(out)'")
      // Defend against silent ASCII-folding on the paste path.
      #expect(out == expected, "accent glyphs must survive verbatim in '\(out)'")
    }
  }

  // MARK: Punctuation-wrapper preservation (prefix/suffix reattach)

  @Test("trailing punctuation is preserved around the corrected apostrophe'd canonical")
  func punctuationWrapperPreserved() {
    let terms = brandsPackTerms()
    #expect(corrected("applebees,", terms) == "Applebee's,")
    #expect(corrected("(loreal)", terms) == "(L'Oréal)")
  }

  // MARK: Kellogg disambiguation

  /// Kellogg's is DEFERRED from #998. It is the only brand with an adjacent
  /// sibling entry — the standalone company/surname `Kellogg` sits one character
  /// from the cereal `Kellogg's`. Empirically, renaming `Kelloggs`→`Kellogg's`
  /// and adding the plain `kelloggs` alias made the bare word `Kellogg` (the
  /// company / Kellogg School / a person) fuzzy-coerce to `Kellogg's` (verified
  /// against old vs new data: old `Kellogg`→`Kellogg`, post-change
  /// `Kellogg`→`Kellogg's`). Data alone can't resolve that boundary, so the
  /// entry is left untouched here. This test locks the safe (unchanged) state so
  /// a future Kellogg's fix can't silently re-introduce the regression.
  @Test("Kellogg's deferred: the company word stays Kellogg, no false coercion")
  func kelloggDeferredSafeState() {
    let terms = brandsPackTerms()
    #expect(corrected("Kellogg", terms) == "Kellogg")
    #expect(corrected("kellag", terms) == "Kellogg")  // company alias still resolves
  }

  // MARK: User precedence — a user term beats the pack alias

  @Test("a user term whose alias equals a brand plain form wins over the pack")
  func userTermBeatsPackAlias() {
    var terms = brandsPackTerms()
    let userWord = CustomWord(
      canonical: "Applebee's Neighborhood Grill", aliases: ["applebees"], source: .user)
    terms.insert(userWord, at: 0)
    #expect(corrected("applebees", terms) == "Applebee's Neighborhood Grill")
  }

  // MARK: Negative class — no new false positives from the short plain aliases

  @Test("common words near short brand aliases are not coerced into a brand")
  func noFalsePositiveFromShortAliases() {
    let terms = brandsPackTerms()
    // Short brands are exact-only (fuzzy gated off), so near-neighbors must pass through.
    for word in ["lower", "lowed", "maces", "moes", "kohl"] {
      #expect(
        corrected(word, terms) == word,
        "'\(word)' must stay unchanged, got '\(corrected(word, terms))'")
    }
  }

  /// Common-word brands (`Patron`, `Dominos`) keep the corrected canonical
  /// spelling but DO NOT get the plain form as an exact alias — adding it would
  /// rewrite the everyday word ("the museum patron arrived", "we played
  /// dominos"). The canonical rename still benefits real mishears. This locks
  /// the common-word safety (Codex code-diff finding).
  @Test("common-word brands do not rewrite the everyday word, but mishears still map")
  func commonWordProtection() {
    let terms = brandsPackTerms()
    // The everyday words pass through untouched.
    #expect(corrected("patron", terms) == "patron")
    #expect(corrected("the museum patron arrived", terms) == "the museum patron arrived")
    #expect(corrected("dominos", terms) == "dominos")
    #expect(corrected("we played dominos", terms) == "we played dominos")
    // But a real mishear still corrects to the proper spelling.
    #expect(corrected("pecron", terms) == "Patrón")
    #expect(corrected("dawmines", terms) == "Domino's")
  }

  // MARK: Existing-alias regression — pre-existing misspellings still map

  @Test("pre-existing misspelling aliases still correct to the now-apostrophe'd canonical")
  func existingAliasesStillMap() {
    let terms = brandsPackTerms()
    #expect(corrected("opelbees", terms) == "Applebee's")
    #expect(corrected("lyrial", terms) == "L'Oréal")
    #expect(corrected("mcdennalls", terms) == "McDonald's")
  }
}
