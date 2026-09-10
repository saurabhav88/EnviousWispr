import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Product expectations for selected ccTLDs in the existing spoken-email grammar.
///
/// **These tests call the normalizer DIRECTLY, bypassing the production language gate.** A
/// German-resolved dictation still skips this formatter at `InverseTextNormalizationStep.skipReason`,
/// so nothing here establishes German product support — it establishes that an ENGLISH-resolved take
/// containing a foreign address now converts.
///
/// The risky half is why the table is a reviewed allowlist rather than every ccTLD. `emails()` matches
/// `<name> at <dom> dot <tld>` where `dom` is any single token, so a ccTLD that is also an ordinary
/// English word has no protection left: admitting `it` converts "he pointed at the dot it made".
/// `refusesWordLikeCountryCodes` holds that line and fails if somebody later "completes" the list from
/// IANA. It protects NAMED risky words; it is not a claim that every admitted entry is unambiguous —
/// `de`, `es` and `si` are dictionary words too.
///
/// URL handling is unchanged. Broadening its spoken-host allowlist would partially convert the
/// spelled-out email in `parity.jsonl`'s `"a at m s n dot fr"`, because `spokenPat`'s path group is
/// `*` rather than `+`.
///
/// **What the frozen fixtures do and do not prove here.** `parity.jsonl` DOES contain a country-code
/// email row (`:1563`), so "no such row exists" would be wrong; what neither it nor the holdout
/// contains is an input matching the newly accepted single-token ccTLD pattern. Passing them
/// establishes agreement with their recorded outputs on THOSE cases, not correctness of this
/// extension. This suite supplies the extension's explicit product expectations.
@Suite("Country-code domains in spoken addresses (#2764)", .tags(.productOutcome))
struct InverseTextNormalizerCountryTLDTests {

  private static let itn = InverseTextNormalizer()

  @Test(
    "a spoken email ending in a country code converts",
    arguments: [
      ("schick das an anna at beispiel dot de", "anna@beispiel.de"),
      ("mandalo a marco at esempio dot fr", "marco@esempio.fr"),
      ("send it to jan at voorbeeld dot nl", "jan@voorbeeld.nl"),
      ("write to maria at ejemplo dot es", "maria@ejemplo.es"),
      ("email me at exemplo dot pt", "me@exemplo.pt"),
      ("reach anna at exempel dot se", "anna@exempel.se"),
      ("contact jan at przyklad dot pl", "jan@przyklad.pl"),
      ("ping ivan at primer dot ru", "ivan@primer.ru"),
      ("mail lars at eksempel dot dk", "lars@eksempel.dk"),
      ("try anna at pelda dot hu", "anna@pelda.hu"),
      ("ask tom at example dot uk", "tom@example.uk"),
      ("ask tom at example dot eu", "tom@example.eu"),
    ] as [(input: String, expected: String)])
  func countryCodeEmailConverts(input: String, expected: String) {
    #expect(Self.itn.normalize(input, spokenPunctuation: false).contains(expected))
  }

  /// The generic domains that already worked must keep working. `alt(...)` re-sorts the whole
  /// alternation when the list grows, so these are regression cover for the existing conversions;
  /// they do not by themselves prove the ordering rule.
  @Test(
    "the existing domains still convert",
    arguments: [
      ("send it to tom at example dot com", "tom@example.com"),
      ("send it to tom at example dot co", "tom@example.co"),
      ("send it to tom at example dot org", "tom@example.org"),
      ("send it to tom at example dot edu", "tom@example.edu"),
    ] as [(input: String, expected: String)])
  func genericDomainsUnaffected(input: String, expected: String) {
    #expect(Self.itn.normalize(input, spokenPunctuation: false).contains(expected))
  }

  /// The line the exclusion list holds. Each of these is an ordinary sentence whose words happen to
  /// land in the `<name> at <dom> dot <tld>` frame; admitting the word-like country code would turn
  /// it into an address.
  @Test(
    "an ordinary sentence is not an address",
    arguments: [
      "he pointed at the dot it made",
      "look at the dot in the corner",
      "she stared at the dot is what I meant",
      "arrive at the dot no later than five",
      "aim at the dot at the top",
      "point at the dot be careful",
      "look at the dot as it moves",
      "look at the dot by the door",
      "look at the dot to your left",
    ])
  func refusesWordLikeCountryCodes(input: String) {
    #expect(!Self.itn.normalize(input, spokenPunctuation: false).contains("@"))
  }

  /// Guards the named exclusions and duplicate entries, not lexical completeness.
  @Test("selected high-risk English words remain excluded")
  func tableExcludesWordLikeCodes() {
    // Named risky words, not a claim of universal unambiguity: `de`, `es` and `si` are dictionary
    // words and ARE admitted. Intersecting a dictionary with the IANA ccTLD list would exclude
    // Germany itself, so the allowlist stays reviewed rather than derived.
    let excluded: Set<String> = [
      "am", "as", "at", "be", "by", "do", "id", "in",
      "is", "it", "my", "no", "so", "to", "us",
    ]
    let table = Set(InverseTextNormalizer.countryCodeTLDs)
    #expect(table.intersection(excluded).isEmpty)
    #expect(table.count == InverseTextNormalizer.countryCodeTLDs.count)  // no duplicates
  }

}
