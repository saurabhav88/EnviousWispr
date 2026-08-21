import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

/// A custom word's own alias, glued to a recognized TLD with no space
/// ("EnviousWispr.com" as one ASR token), must correct the word AND keep the
/// domain suffix — never silently drop it.
///
/// Measured live from the founder's own dictation, 2026-08-21: "Enviousvisper.com"
/// corrected to "EnviousWispr" with the ".com" gone entirely. Root cause:
/// `WordCorrector.splitPunctuation` only strips LEADING/TRAILING characters
/// that are not letters or numbers, so a token ending in a letter ("...com")
/// never gets its internal "." recognized as a boundary at all — the whole
/// glued string, TLD included, was handed to the matching passes as one
/// "core", and a match replaced the entire thing.
@Suite("WordCorrector — a glued domain suffix survives correction", .tags(.productOutcome))
struct WordCorrectorGluedDomainSuffixTests {

  private static let enviousWispr = CustomWord(
    canonical: "EnviousWispr",
    aliases: [
      "envious visper", "envious whisper", "envious wisper",
      "mbs cisper", "envious cisper", "envious wispr",
      "in vious wispr", "envy us wispr", "NVS Visper", "NBS Vesper",
      "Enviousvisper",
    ],
    category: .brand)

  private func corrected(_ input: String, _ terms: [CustomWord] = [enviousWispr]) -> (
    text: String, replacements: Int
  ) {
    let result = WordCorrector().correct(input, against: terms)
    return (result.corrected, result.replacements.count)
  }

  @Test("A no-space alias glued directly to a recognized TLD keeps the TLD")
  func gluedAliasKeepsTLD() {
    // The founder's own reproduction, exactly. Regression pin for #2258-adjacent.
    let result = corrected("Enviousvisper.com")
    #expect(result.text == "EnviousWispr.com")
    #expect(result.replacements == 1)
  }

  @Test(
    "Every recognized TLD is preserved, not only .com",
    arguments: ["com", "org", "io", "co", "dev", "me", "net", "ai", "app", "xyz"])
  func everyRecognizedTLDIsPreserved(_ tld: String) {
    let result = corrected("Enviousvisper.\(tld)")
    #expect(result.text == "EnviousWispr.\(tld)")
    #expect(result.replacements == 1)
  }

  @Test("An UNRECOGNIZED trailing suffix is left as part of the match, unchanged shape")
  func unrecognizedSuffixIsNotTreatedAsATLD() {
    // ".zzz" is not in the closed TLD list this fix reuses, so the token is
    // handled exactly as before this fix -- no special-casing invented for
    // strings that merely look domain-shaped.
    let result = corrected("Enviousvisper.zzz")
    #expect(result.text != "EnviousWispr.zzz")
  }

  @Test("A fuzzy (near-miss spelling) match ALSO keeps a glued TLD")
  func fuzzyMatchAlsoKeepsGluedTLD() {
    // "EnviousWhisper" is not a registered alias verbatim, so this exercises
    // the SIMILARITY-scored passes, not the exact/no-space passes above --
    // previously this input corrected NOTHING (the ".com" noise pulled the
    // similarity score below threshold), matching the founder's third
    // dictation ("EnviousWhisper.com" -> "no change").
    let result = corrected("EnviousWhisper.com")
    #expect(result.text == "EnviousWispr.com")
    #expect(result.replacements == 1)
  }

  @Test("A glued TLD inside a full sentence still corrects and keeps the domain")
  func gluedTLDInsideASentenceStillWorks() {
    let result = corrected("Hey, I keep trying to say Enviousvisper.com but it never works")
    #expect(result.text == "Hey, I keep trying to say EnviousWispr.com but it never works")
    #expect(result.replacements == 1)
  }

  @Test("The spaced alias form is unaffected — regression pin")
  func spacedAliasFormUnaffected() {
    let result = corrected("envious visper dot com")
    // No TLD glued to a single token here ("dot com" is two ordinary spoken
    // words) -- this fix's new branch never engages, and the alias still
    // corrects exactly as it always has.
    #expect(result.text == "EnviousWispr dot com")
    #expect(result.replacements == 1)
  }

  @Test("A TLD-shaped suffix on a word that matches NOTHING is left alone")
  func noMatchLeavesTheTokenAlone() {
    let result = corrected("totallyunrelatedword.com")
    #expect(result.text == "totallyunrelatedword.com")
    #expect(result.replacements == 0)
  }

  // MARK: Codex review findings (PR for #2281) — a saved alias that IS itself
  // a domain must not have its TLD peeled off before the exact lookup runs,
  // and a domain-shaped token must never feed the COMPOUND (multi-token)
  // passes and lose its TLD there instead.

  private static let gitHubDomainAlias = CustomWord(
    canonical: "GitHub.com", aliases: ["githab.com"], category: .brand)

  @Test("An exact alias that is ITSELF a domain still matches whole, unpeeled")
  func exactDomainShapedAliasStillMatches() {
    let result = corrected("githab.com", [Self.gitHubDomainAlias])
    #expect(result.text == "GitHub.com")
    #expect(result.replacements == 1)
  }

  private static let fooBar = CustomWord(
    canonical: "FooBar", aliases: ["foobar"], category: .brand)

  @Test(
    "A domain-shaped token before another word does not feed compound matching and lose its TLD")
  func domainTokenDoesNotFeedCompoundMatch() {
    // "foo.com" + "bar" superficially concatenates to "foobar" -- an accident
    // compound Pass 0 must not act on. Domain-bearing tokens stay opaque to
    // the compound passes exactly as they were before this fix.
    let result = corrected("foo.com bar", [Self.fooBar])
    #expect(result.text == "foo.com bar")
    #expect(result.replacements == 0)
  }

  @Test("Every recognized TLD survives a FUZZY (not just exact) single-word match")
  func everyRecognizedTLDSurvivesFuzzyMatch() {
    // Regression for the fix's own false start: trying the fuzzy passes on
    // the unpeeled token FIRST let several TLD lengths cross threshold and
    // get silently swallowed (org/net/ai/me/io/app all failed before this
    // was caught and corrected). Re-assert every TLD through the fuzzy path
    // specifically, using a near-miss spelling rather than the exact alias.
    for tld in ["com", "org", "io", "co", "dev", "me", "net", "ai", "app", "xyz"] {
      let result = corrected("EnviousWhisper.\(tld)")
      #expect(result.text == "EnviousWispr.\(tld)", "TLD '\(tld)' should survive a fuzzy match")
      #expect(result.replacements == 1, "TLD '\(tld)' should still count as one replacement")
    }
  }

  private static let gitHubBareAlias = CustomWord(
    canonical: "GitHub.com", aliases: ["githab"], category: .brand)

  @Test("A peeled TLD is not duplicated when the matched canonical already carries it")
  func peeledTLDNotDuplicatedWhenCanonicalAlreadyHasIt() {
    // Codex review round 2: canonical "GitHub.com" already IS a domain, but
    // its alias "githab" is bare. "githab.com" misses the (unpeeled) exact
    // Pass 3 -- the alias has no ".com" -- so it falls into the peel-and-
    // retry path, where "githab" DOES exact-match. Blindly reattaching the
    // peeled ".com" would produce "GitHub.com.com".
    let result = corrected("githab.com", [Self.gitHubBareAlias])
    #expect(result.text == "GitHub.com")
    #expect(result.replacements == 1)
  }
}
