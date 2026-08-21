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
}
