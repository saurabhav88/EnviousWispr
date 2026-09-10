import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// A spoken address ending in a country-code domain now converts, and the ordinary sentences that
/// look like one still do not.
///
/// Why this exists: `emailTLDAlt` and `lowerRiskURLTLDAlt` carried no country code at all, so
/// `anna at beispiel dot de` stayed spelled out — for a German speaker AND for an English speaker
/// dictating a German address. Measured on #1677's engine survey, every non-English address in the
/// corpus ends in a country code, so the missing list blocked the whole category before any
/// per-language work could matter.
///
/// The risky half is the reason the table is a list rather than "every ccTLD". `emails(_:)` matches
/// `<name> at <dom> dot <tld>` where `dom` is any single token, so a ccTLD that is also an ordinary
/// English word has no protection left: admitting `it` converts "he pointed at the dot it made".
/// Those are excluded, and `refusesWordLikeCountryCodes` is what holds that line — it fails if
/// somebody later "completes" the list from IANA.
///
/// **EMAIL ONLY, and the reason is the oracle, not the risk.** `lowerRiskURLTLDAlt` deliberately did
/// NOT get these codes. `spokenPat`'s path is optional (`*`), so a bare `<host> dot <tld>` converts
/// with no path at all, and adding `fr` turned the curated parity row `"a at m s n dot fr"` — a
/// person spelling out MSN — into `"a at m s n.fr"`. `parity.jsonl` is baked from a Python oracle
/// (`hand_rolled.py`) that is NOT in this repo or on this machine, so that row cannot be re-baked
/// here and the URL half is blocked until it can be. #2764 carries that.
///
/// **Honest limit on the email half:** no parity row exercises a country-code email, so parity
/// passing means "no regression", NOT "matches the oracle". These conversions are a deliberate
/// divergence the oracle would not make, and this suite is the only thing asserting them.
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

  /// The generic domains that already worked must keep working — this list grew by 26 entries and
  /// `alt(...)` re-sorts the whole alternation, so a longest-first regression would show up here
  /// as `example.co` swallowing `example.com`.
  @Test(
    "the generic domains still convert, and the longer one still wins",
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
    ])
  func refusesWordLikeCountryCodes(input: String) {
    #expect(!Self.itn.normalize(input, spokenPunctuation: false).contains("@"))
  }

  /// Structural guard on the table itself, so the reason survives without depending on a reviewer
  /// remembering it. A word-like code added here would pass every conversion test above and only
  /// fail the sentences — this fails at the source instead.
  @Test("no country code in the table is an ordinary English word")
  func tableExcludesWordLikeCodes() {
    let wordLike: Set<String> = [
      "it", "at", "in", "is", "be", "no", "so", "us", "my", "am", "do", "id",
    ]
    let table = Set(InverseTextNormalizer.countryCodeTLDs)
    #expect(table.intersection(wordLike).isEmpty)
    #expect(table.count == InverseTextNormalizer.countryCodeTLDs.count)  // no duplicates
  }

}
