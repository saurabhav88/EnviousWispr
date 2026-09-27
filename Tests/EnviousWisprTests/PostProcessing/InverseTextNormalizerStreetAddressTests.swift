import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// A dictated US street address gets its numbers written and its commas (#3211).
///
/// **When this fails, a speaker who says "nine High Plains Road Shelton Connecticut zero six four
/// eight four" pastes it without commas or with spelled numbers, or an ordinary sentence that
/// names a road, a city or a state gains digits and commas.** Product coverage. Expected outputs
/// are written by hand. The recogniser rows are verbatim Parakeet and WhisperKit output for Azure
/// clips (`docs/audits/2026-09-26-3211-baseline-azure/`, main checkout); the founder rows are his
/// own dictations from 2026-09-26.
@Suite("ITN formats dictated US street addresses (#3211)", .tags(.productOutcome))
struct InverseTextNormalizerStreetAddressTests {

  private func english(_ s: String) -> String {
    InverseTextNormalizer().normalize(s, spokenPunctuation: false)
  }

  nonisolated static let rows: [(dictated: String, expected: String)] = [
    // founder, 2026-09-26
    (
      "9 High Plains Road Shelton Connecticut 06484",
      "9 High Plains Road, Shelton, Connecticut 06484"
    ),
    (
      "Three twenty West Thirty Eighth Street, apartment two twenty, New York, New York one zero zero one eight.",
      "320 West 38th Street, apartment 220, New York, New York 10018."
    ),
    (
      "My parents live at nine High Plains Road, Shelton, Connecticut, 06484.",
      "My parents live at 9 High Plains Road, Shelton, Connecticut 06484."
    ),
    // Parakeet, verbatim
    (
      "Please send the replacement key to Nine High Plains Road Shelton, Connecticut 06484, since the old one was misplaced during the move.",
      "Please send the replacement key to 9 High Plains Road, Shelton, Connecticut 06484, since the old one was misplaced during the move."
    ),
    (
      "Forward the medical records to Eleven Garden Lane, New Haven, Connecticut zero six five one nine, after the patient confirms the mailing address.",
      "Forward the medical records to 11 Garden Lane, New Haven, Connecticut 06519, after the patient confirms the mailing address."
    ),
    (
      "When the driver calls, direct her to forty two Oak Lane, Apartment seven, Boston, Massachusetts zero two one zero eight, and ask her to use the side entrance.",
      "When the driver calls, direct her to 42 Oak Lane, Apartment 7, Boston, Massachusetts 02108, and ask her to use the side entrance."
    ),
    (
      "The courier should bring the samples to eighty eight Market Avenue, Floor three, San Francisco, California nine four one zero five before the afternoon review begins.",
      "The courier should bring the samples to 88 Market Avenue, Floor 3, San Francisco, California 94105 before the afternoon review begins."
    ),
    // WhisperKit, English locked, verbatim
    (
      "Mail the hearing notice to 100 Pennsylvania Avenue, Washington, District of Columbia, 20004, and keep a copy with the case file.",
      "Mail the hearing notice to 100 Pennsylvania Avenue, Washington, District of Columbia 20004, and keep a copy with the case file."
    ),
    (
      "Send the final invoice to 50 Maple Place, Washington, District of Columbia, 20001-1234 and include the purchase order.",
      "Send the final invoice to 50 Maple Place, Washington, District of Columbia 20001-1234 and include the purchase order."
    ),
    // shapes: pair and digit house numbers, units, spoken ZIP+4, a code, a kept line break
    (
      "Send it to one oh one Elm Avenue New Haven Connecticut zero six five one zero dash one two three four please.",
      "Send it to 101 Elm Avenue, New Haven, Connecticut 06510-1234 please."
    ),
    // the whole spoken house number, never its tail (Codex diff review r1)
    (
      "one hundred and twenty three Main Street Hartford Connecticut 06103",
      "123 Main Street, Hartford, Connecticut 06103"
    ),
    (
      "It is at two thousand and five Oak Lane Denver Colorado 80203.",
      "It is at 2005 Oak Lane, Denver, Colorado 80203."
    ),
    // Codex diff review r2: a ZIP opened by the letter "o", a unit letter written apart, a unit
    // number of four words
    (
      "9 Main Street Hartford Connecticut o six one zero three",
      "9 Main Street, Hartford, Connecticut 06103"
    ),
    (
      "Deliver to 900 Harbor Boulevard Suite 4 B Miami Florida 33131.",
      "Deliver to 900 Harbor Boulevard, Suite 4B, Miami, Florida 33131."
    ),
    (
      "9 Main Street Suite one hundred twenty three Miami Florida 33131",
      "9 Main Street, Suite 123, Miami, Florida 33131"
    ),
    // Codex diff review r4: a written ZIP with a spoken +4; a line break before the ZIP
    (
      "9 Main Street Hartford Connecticut 06103 dash one two three four",
      "9 Main Street, Hartford, Connecticut 06103-1234"
    ),
    (
      "nine Main Street\nHartford\nConnecticut\nzero six one zero three",
      "9 Main Street\nHartford\nConnecticut\n06103"
    ),
    // Codex diff review r5: a conjunction before a spoken house number
    (
      "Mail the documents and nine High Plains Road Shelton Connecticut 06484",
      "Mail the documents and 9 High Plains Road, Shelton, Connecticut 06484"
    ),
    // Codex diff review r8: a pair ending in ten to nineteen
    (
      "Send it to one ten Main Street Hartford Connecticut 06103",
      "Send it to 110 Main Street, Hartford, Connecticut 06103"
    ),
    // Codex diff review r9: a city with a lowercase connector
    (
      "nine Main Street City of Industry California 91744",
      "9 Main Street, City of Industry, California 91744"
    ),
    // Codex diff review r10: a line break inside a spoken ZIP; a quantity after a written ZIP
    (
      "nine High Plains Road, Shelton, Connecticut zero six\nfour eight four",
      "9 High Plains Road, Shelton, Connecticut 06484"
    ),
    (
      "9 High Plains Road Shelton Connecticut 06484 two days from now",
      "9 High Plains Road, Shelton, Connecticut 06484 two days from now"
    ),
    // Codex diff review r11/r12: a city may open with St., Ft. or Mt.
    (
      "Ship to 100 Market Street St. Louis Missouri 63101 today.",
      "Ship to 100 Market Street, St. Louis, Missouri 63101 today."
    ),
    // Codex diff review r13: any line break is kept as written
    (
      "9 Main Street\rHartford Connecticut 06103",
      "9 Main Street\rHartford, Connecticut 06103"
    ),
    (
      "9 Main Street\r\nHartford\r\nConnecticut\r\n06103",
      "9 Main Street\r\nHartford\r\nConnecticut\r\n06103"
    ),
    // an address opening its own line keeps the line start tight (no pad space)
    (
      "Deliver it here:\n9 Main Street Hartford Connecticut 06103",
      "Deliver it here:\n9 Main Street, Hartford, Connecticut 06103"
    ),
    // a real sentence end still lets the next address start
    (
      "I moved last week. 9 Main Street Hartford Connecticut 06103 is the new place.",
      "I moved last week. 9 Main Street, Hartford, Connecticut 06103 is the new place."
    ),
    (
      "It goes to fifteen twenty Main Street Hartford Connecticut 06103.",
      "It goes to 1520 Main Street, Hartford, Connecticut 06103."
    ),
    (
      "Deliver to 900 Harbor Boulevard Suite four B Miami Florida 33131.",
      "Deliver to 900 Harbor Boulevard, Suite 4B, Miami, Florida 33131."
    ),
    (
      "Ship it to 100 Pennsylvania Avenue, Washington, DC 20500.",
      "Ship it to 100 Pennsylvania Avenue, Washington, DC 20500."
    ),
    (
      "Ship it to 100 Pennsylvania Avenue\nWashington DC 20500 today.",
      "Ship it to 100 Pennsylvania Avenue\nWashington, DC 20500 today."
    ),
  ]

  @Test("a dictated address is written with digits and commas", arguments: rows)
  func row(row: (dictated: String, expected: String)) {
    #expect(english(row.dictated) == row.expected)
  }

  /// Each needs the whole address: a road, a city or a state alone, a five-digit ID, a year, or
  /// an address with no state or ZIP stays exactly as the recogniser wrote it.
  nonisolated static let controls: [String] = [
    "We met at three twenty near the station.",
    "Take 9 High Plains Road toward Shelton, then turn left.",
    "We walked down High Plains Road before sunrise.",
    "The report numbered 10018 was filed today.",
    "Court Street, Brooklyn is where we met in 2019.",
    "She moved from Washington to Oregon in 2020 and back in 2021.",
    "The Main Street festival draws 50000 people.",
    "Revenue for 2019 Main Street Bank Denver Colorado 80203 rose.",
    "Georgia Way told Indiana Place about the Virginia Court ruling.",
    "Ticket 48213 covers the Washington Court hearing.",
    "The Place Street sign in Virginia fell over.",
    "Order 12 copies of Main Street Stories for Georgia 30301 readers.",
    "Nine people live on High Plains Road in Shelton, Connecticut.",
    "Apartment seven is empty.",
    "Meet me at 9 High Plains Road Shelton Connecticut.",
    "Room two twenty is booked for Friday.",
    "Take 9 High Plains Road toward Shelton Connecticut 06484 and turn left.",
    "Send it to 9 High Plains Road Shelton Connecticut 064841 today.",
    // Codex diff review r11: a name never runs through a time or a sentence end
    "We met at 9 A.M. Main Street Hartford Connecticut 06103 was the next topic.",
    "The rope is 9 Ft. Main Street Hartford Connecticut 06103 is the next entry.",
    // Codex diff review r14: a street, unit or city name never spans a line break
    "Send it to nine Main Street Hartford\nCourt Connecticut 06103 as two separate entries.",
    "Send it to nine Main Street Hartford\nNew Haven Connecticut 06103 as two entries.",
    "Deliver to 9 Main Street Suite two\u{2028}twenty Hartford Connecticut 06103.",
  ]

  @Test("prose that is not a whole address is left alone", arguments: controls)
  func control(text: String) {
    #expect(english(text) == text)
  }

  /// Accepted miss (plan §2.2): a written year after a time word is never a house number, so a
  /// real address that starts with one stays as spoken.
  @Test("a year-shaped house number after a time word stays as spoken")
  func yearGuardMiss() {
    let s = "Shipped from 2001 Main Street, Hartford Connecticut 06103."
    #expect(english(s) == s)
  }

  /// A house number longer than the pass reads is refused whole, never cut to its tail: the
  /// cardinal pass writes the number and no commas are added.
  @Test("a house number too long to read is left to the number pass")
  func tooLongHouseNumber() {
    let s = "nine hundred ninety nine thousand nine hundred ninety nine Main Street Hartford Connecticut 06103"
    let out = "999,999 Main Street Hartford Connecticut 06103"
    #expect(english(s) == out)
    #expect(english(out) == out)
  }

  /// Codex diff review r3: a spoken year after a time word, and a spoken ZIP running into a written
  /// digit, are not addresses. The year and digit-read passes still write their numbers, as on main.
  nonisolated static let notAddresses: [(dictated: String, expected: String)] = [
    (
      "Revenue for twenty twenty Main Street Bank Denver Colorado 80203 rose.",
      "Revenue for 2020 Main Street Bank Denver Colorado 80203 rose."
    ),
    (
      "Send it to 9 Main Street Hartford Connecticut zero six four eight four 1 today.",
      "Send it to 9 Main Street Hartford Connecticut 064841 today."
    ),
    // Codex diff review r6: a ZIP+4 cut short, and a year after a time word
    (
      "Send it to 9 Main Street Hartford Connecticut 02108 dash one two today.",
      "Send it to 9 Main Street Hartford Connecticut 02108 dash one two today."
    ),
    (
      "Figures from 2019 Main Street Bank Denver Colorado 80203 arrived.",
      "Figures from 2019 Main Street Bank Denver Colorado 80203 arrived."
    ),
    // Codex diff review r10: a SPOKEN ZIP running into another digit word may be a longer number
    (
      "9 High Plains Road Shelton Connecticut zero six four eight four two days from now",
      "9 High Plains Road Shelton Connecticut 064842 days from now"
    ),
    // Codex diff review r4: a written house number after spoken number words is the tail of one number
    (
      "one hundred and 23 Main Street Hartford Connecticut 06103",
      "100 and 23 Main Street Hartford Connecticut 06103"
    ),
  ]

  /// Cloud review and its class enumeration (docs/audits/2026-09-26-3211-cloud-class-enum.txt):
  /// a time, date, price, label, range, time zone or unit right before an address-shaped span
  /// never lends it a house number. Expected output is origin/main's own.
  nonisolated static let borrowedNumbers: [(dictated: String, expected: String)] = [
    ("We meet at 9 AM Main Street Hartford Connecticut 06103.", "We meet at 9:00 AM Main Street Hartford Connecticut 06103."),
    ("On 9/12 Main Street Hartford Connecticut 06103.", "On 9/12 Main Street Hartford Connecticut 06103."),
    ("It costs $9 Main Street Hartford Connecticut 06103.", "It costs $9 Main Street Hartford Connecticut 06103."),
    ("June second twenty twenty six Main Street Hartford Connecticut 06103.", "June 2, 2026 Main Street Hartford Connecticut 06103."),
    ("No. 9 Main Street Hartford Connecticut 06103.", "No. 9 Main Street Hartford Connecticut 06103."),
    ("at 9 UTC Main Street Hartford Connecticut 06103.", "at 9 UTC Main Street Hartford Connecticut 06103."),
    ("room 12 Main Street Hartford Connecticut 06103.", "room 12 Main Street Hartford Connecticut 06103."),
    ("exit 9 Main Street Hartford Connecticut 06103.", "exit 9 Main Street Hartford Connecticut 06103."),
    ("chapter 9 Main Street Hartford Connecticut 06103.", "chapter 9 Main Street Hartford Connecticut 06103."),
    ("9 - 11 Main Street Hartford Connecticut 06103.", "9 - 11 Main Street Hartford Connecticut 06103."),
    ("9 FT Main Street Hartford Connecticut 06103.", "9 FT Main Street Hartford Connecticut 06103."),
    ("Room 12 Main Street Hartford Connecticut 06103.", "Room 12 Main Street Hartford Connecticut 06103."),
    ("Chapter 9 Main Street Hartford Connecticut 06103.", "Chapter 9 Main Street Hartford Connecticut 06103."),
    ("Gate 9 Main Street Hartford Connecticut 06103.", "Gate 9 Main Street Hartford Connecticut 06103."),
    // Codex diff review r17: any word that labels the number, not only listed ones
    ("See section 9 Main Street Hartford Connecticut 06103 for details.", "See section 9 Main Street Hartford Connecticut 06103 for details."),
    ("Ask about No. 9 Main Street Hartford Connecticut 06103 today.", "Ask about No. 9 Main Street Hartford Connecticut 06103 today."),
    ("Ask about no. 9 Main Street Hartford Connecticut 06103 today.", "Ask about no. 9 Main Street Hartford Connecticut 06103 today."),
    // Codex diff review r18: an abbreviation is not a sentence end
    ("See Sec. 9 Main Street Hartford Connecticut 06103 for details.", "See Sec. 9 Main Street Hartford Connecticut 06103 for details."),
    ("See fig. 9 Main Street Hartford Connecticut 06103 for details.", "See fig. 9 Main Street Hartford Connecticut 06103 for details."),
  ]

  @Test("a number that belongs to the words before it is not a house number", arguments: borrowedNumbers)
  func borrowedNumber(row: (dictated: String, expected: String)) {
    #expect(english(row.dictated) == row.expected)
  }

  @Test("a year or a longer digit run is not read as an address", arguments: notAddresses)
  func notAddress(row: (dictated: String, expected: String)) {
    #expect(english(row.dictated) == row.expected)
  }

  @Test("a formatted address is not changed again", arguments: rows)
  func idempotent(row: (dictated: String, expected: String)) {
    #expect(english(row.expected) == row.expected)
  }

  /// The address pass runs only on the English route: a take resolved as another language keeps
  /// the recogniser's text (no English number words, no added commas).
  @Test("a non-English take never reads the address", arguments: rows)
  func neutralRoute(row: (dictated: String, expected: String)) {
    #expect(InverseTextNormalizer().normalizeLanguageNeutral(row.dictated) == row.dictated)
  }
}
