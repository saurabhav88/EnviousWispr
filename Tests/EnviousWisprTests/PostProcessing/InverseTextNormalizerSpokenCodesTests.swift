import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Spoken versions, IP addresses, dashed codes, dashed dates, localhost ports and multi-dot
/// addresses convert whole (#3210).
///
/// **When this fails, a dictated "version two point five point zero" pastes "2.5 point zero",
/// "S dash one" stays as words, or "www dot example dot com" stays as words.** Product coverage.
/// The founder rows are verbatim `[RAW ASR]` lines from his `app.log` (2026-09-26); the Parakeet
/// rows are what the shipping model wrote for Mac TTS clips
/// (`docs/audits/2026-09-26-3210-spoken-codes/parakeet.jsonl`).
@Suite("ITN converts spoken identifiers whole (#3210)", .tags(.productOutcome))
struct InverseTextNormalizerSpokenCodesTests {

  private func itn(_ s: String) -> String {
    InverseTextNormalizer().normalize(s, spokenPunctuation: false)
  }

  nonisolated static let englishRows: [(dictated: String, expected: String)] = [
    // founder dictations, RAW ASR
    ("Version two point five point zero.", "Version 2.5.0."),
    ("One nine two dot one six eight dot one dot one.", "192.168.1.1."),
    ("S dash one.", "S-1."),
    ("Test question B dash two.", "Test question B-2."),
    // Live UAT, Parakeet in the app: the recogniser wrote the hyphen and left the number spoken
    ("The part number is s- one.", "The part number is S-1."),
    ("The part number is s dash one.", "The part number is S-1."),
    ("The F- sixteen landed.", "The F-16 landed."),
    ("Https colon slash slash www.envisvisper dot com.", "https://www.envisvisper.com"),
    ("https colon slash slash example dot com.", "https://example.com"),
    ("W dot nvsvisper dot com.", "www.nvsvisper.com"),
    (
      "page clarify that E G dash one isn't open source?",
      "page clarify that EG-1 isn't open source?"
    ),
    // shapes already half-converted by the recogniser (founder history)
    (
      "I was on version 2.0 point zero and I was waiting",
      "I was on version 2.0.0 and I was waiting"
    ),
    (
      "why these people on 2.3 point two and two point three point one are not",
      "why these people on 2.3.2 and 2.3.1 are not"
    ),
    ("The date is 2026-9-26.", "The date is 2026-09-26."),
    // the approved scope
    ("Install Python three point twelve.", "Install Python 3.12."),
    ("See section three point two point one.", "See section 3.2.1."),
    ("The F dash sixteen landed.", "The F-16 landed."),
    // founder decision 2026-09-26: a spoken dash gives "GPT-40" (with no dash, "GPT 40")
    ("Try GPT dash four o.", "Try GPT-40."),
    ("COVID dash nineteen cases.", "COVID-19 cases."),
    ("Part S dash one hundred and two failed.", "Part S-102 failed."),
    ("Install Python three Point twelve.", "Install Python 3.12."),
    ("The date is twenty twenty six dash nine dash twenty six.", "The date is 2026-09-26."),
    ("Open localhost colon three thousand.", "Open localhost:3000."),
    ("Open localhost colon three thousand and one.", "Open localhost:3001."),
    ("Visit www dot example dot com today", "Visit www.example.com today"),
    ("Go to docs dot example dot com today", "Go to docs.example.com today"),
    ("Visit www dot google dot co dot uk today", "Visit www.google.co.uk today"),
    ("Visit www dot example dot com slash help today", "Visit www.example.com/help today"),
    (
      "Open https colon slash slash www.example.com slash help today",
      "Open https://www.example.com/help today"
    ),
    ("Email me at john dot smith at gmail dot com today", "Email me at john.smith@gmail.com today"),
    (
      "Email me at john dot smith at mail dot example dot com today",
      "Email me at john.smith@mail.example.com today"
    ),
    ("Part S dash one thousand and one failed.", "Part S-1001 failed."),
  ]

  @Test("converts the whole identifier", arguments: englishRows)
  func englishRow(row: (dictated: String, expected: String)) {
    #expect(itn(row.dictated) == row.expected, "\"\(row.dictated)\"")
  }

  /// What must stay as spoken. Each is either prose that shares a connector word, or an
  /// identifier with a part the passes cannot read, which must stay whole rather than half.
  nonisolated static let controls: [(dictated: String, expected: String)] = [
    // one "point" is still a decimal, and a trailing non-number is not a chain
    ("at one point two point guards", "at 1.2 point guards"),
    // a cardinal minor version needs a name before it, not a sentence-start function word
    ("At one point twelve people left.", "At one point 12 people left."),
    // "dash" as prose, and the pronoun
    ("Make a dash for it.", "Make a dash for it."),
    ("It was a- one of a kind", "It was a- one of a kind"),
    ("add a dash two times", "add a dash two times"),
    // a spelled-out word ending in a letter before "dash" is not a code (parity holdout shape)
    ("l i s t dash o f banks", "l i s t dash o f banks"),
    ("Then I dash two things off.", "Then I dash two things off."),
    ("we dash two emails off", "we dash two emails off"),
    // an identifier with an unreadable part stays whole: no "2.5 point x" halves
    (
      "two two five dot double five dot o dot four o",
      "two two five dot double five dot o dot four o"
    ),
    ("version one point two point three point x", "version one point two point three point x"),
    // the next two are byte-identical to origin/main: the new passes refuse them, and what the
    // older passes then write is a pre-existing limit, not new
    ("open https colon slash slash docs dot example dot com slash help question mark q",
     "open https colon slash slash docs dot example dot com/help question mark q"),
    ("version one hundred and two dot three dot four", "version 100 and two dot three dot four"),
    ("version 2.5 point twenty point x", "version 2.5 point twenty point x"),
    // the minor-version pass refuses this; the cardinal pass then writes "12" exactly as it did
    // before #3210 (a pre-existing limit, not a new half-conversion)
    ("Install Python three point twelve point x", "Install Python three point 12 point x"),
    ("the part is A dash B dash one", "the part is A dash B dash one"),
    ("the code S dash one dash x", "the code S dash one dash x"),
    ("rows S dash 12 and 3 failed", "rows S-12 and 3 failed"),
    ("the tag S dash 1 2 again", "the tag S dash 1 2 again"),
    ("the build 2026 dash 9 dash 2 6", "the build 2026 dash 9 dash 2 6"),
    ("the date 2026 dash 2 dash 31", "the date 2026 dash 2 dash 31"),
    // a literal URL or path segment is left exactly as written
    ("see https://example.com/2026-9-26 today", "see https://example.com/2026-9-26 today"),
    ("see https://example.com?date=2026-9-26 today", "see https://example.com?date=2026-9-26 today"),
    ("write to 2026-9-26@example.com today", "write to 2026-9-26@example.com today"),
    ("open 2026-9-26.com today", "open 2026-9-26.com today"),
    ("filed 2026-2-31", "filed 2026-2-31"),
    ("filed 2028-2-29", "filed 2028-02-29"),
    // a chain the English path refuses (a foreign dot-word beside number words) stays whole
    ("Version twelve Punkt 5 Punkt 0", "Version twelve Punkt 5 Punkt 0"),
    ("the build ID is 2026-9-26 dash one", "the build ID is 2026-9-26 dash one"),
    ("open https colon slash slash example dot de", "open https colon slash slash example dot de"),
    ("open https colon slash slash one dot com", "open https colon slash slash one dot com"),
    ("open https colon slash slash docs dot example dot com question mark page",
     "open https colon slash slash docs dot example dot com question mark page"),
    ("open https colon slash slash docs dot example dot com dot xyz",
     "open https colon slash slash docs dot example dot com dot xyz"),
    // an address that goes on past an ending this file reads stays whole
    ("mail john dot smith at gmail dot com dot xyz", "mail john dot smith at gmail dot com dot xyz"),
    ("see docs dot example dot com dot xyz", "see docs dot example dot com dot xyz"),
    // a domain the recogniser already joined stays as spoken, the class #2770 closed
    // (`InverseTextNormalizerDottedEmailTests`): no spoken dot-word, no address
    ("she works at example.com", "she works at example.com"),
    // a one-word name before a multi-label domain after "at" is a website in prose
    ("Read the docs at docs dot example dot com", "Read the docs at docs.example.com"),
    ("Email john at mail.example.com", "Email john at mail.example.com"),
    ("and my email is Sarah.chen at gmail.com.", "and my email is Sarah.chen at gmail.com."),
    // a dotted name that is a file keeps its "at", even with a spoken dot in the domain
    ("download report.pdf at example dot com", "download report.pdf at example.com"),
    // an impossible date or port is left alone
    ("The code is 2026-13-40.", "The code is 2026-13-40."),
    ("localhost colon seventy thousand", "localhost colon 70,000"),
    // a spoken protocol with no host after it
    ("type https colon slash slash then the name", "type https colon slash slash then the name"),
  ]

  @Test("what must not move", arguments: controls)
  func controlRow(row: (dictated: String, expected: String)) {
    #expect(itn(row.dictated) == row.expected, "\"\(row.dictated)\"")
  }

  @Test("one pass is enough: a second pass over the output changes nothing")
  func idempotent() {
    for row in Self.englishRows {
      let once = itn(row.dictated)
      #expect(itn(once) == once, "\"\(row.dictated)\"")
    }
  }

  @Test("the spoken-punctuation setting does not change any identifier row")
  func sameWithSpokenPunctuationOn() {
    for row in Self.englishRows {
      #expect(
        InverseTextNormalizer().normalize(row.dictated, spokenPunctuation: true) == row.expected,
        "\"\(row.dictated)\"")
    }
  }

  // MARK: - The language-neutral subset (non-English takes)

  /// Parakeet's output for Mac TTS clips in five languages, plus address shapes with each
  /// language's at-word. The neutral subset reads digits and table words only.
  nonisolated static let neutralRows: [(dictated: String, expected: String)] = [
    ("S trattino 1.", "S-1."),
    ("S traço 1.", "S-1."),
    ("Version 2 Punkt 5 Punkt 0.", "Version 2.5.0."),
    ("Frage B Bindestrich 2.", "Frage B-2."),
    ("Schreib an max.mustermann at gmail punkt com", "Schreib an max.mustermann@gmail.com"),
    ("Escribe a juan.perez arroba gmail punto com", "Escribe a juan.perez@gmail.com"),
    ("Escribe a juan arroba gmail punto com", "Escribe a juan@gmail.com"),
    ("Das Datum ist 2026-9-26.", "Das Datum ist 2026-09-26."),
  ]

  @Test("non-English identifiers convert", arguments: neutralRows)
  func neutralRow(row: (dictated: String, expected: String)) {
    #expect(
      InverseTextNormalizer().normalizeLanguageNeutral(row.dictated) == row.expected,
      "\"\(row.dictated)\"")
  }

  /// The subset must never read English number or time words on a foreign take: German `am`
  /// is not the meridiem and Polish `ten` is not 10 (#2763's measured collisions).
  nonisolated static let neutralControls: [String] = [
    "Wir treffen uns um 7 am Abend.",
    "ten dom jest duży",
    "Version zwei Punkt fünf Punkt null.",
    "S dash one.",
    "Schreib an max.mustermann at gmail.com",
    "version 1 2 Punkt 3 Punkt 4",
    "Ich arbeite at example dot com",
    "Escribe a juan.perez arroba gmail.com",
    "Ich wohne in der Straße 12, zweiter Stock.",
    "  Zwei  Leerzeichen\nund eine neue Zeile  ",
  ]

  @Test("the neutral subset leaves words and whitespace byte-identical", arguments: neutralControls)
  func neutralControl(text: String) {
    #expect(Array(InverseTextNormalizer().normalizeLanguageNeutral(text).utf8) == Array(text.utf8))
  }
}
