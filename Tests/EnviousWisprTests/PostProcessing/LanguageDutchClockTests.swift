import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - Dutch clock times through the production language route (#1677)
//
// Inputs are engine output: measured on Azure TTS through Parakeet and WhisperKit, and transcribed
// from real Dutch vlogs and podcasts (`docs/audits/2026-10-06-1677-pl-ru-nl-youtube`,
// `2026-10-06-1677-podcast-speech`). Expected outputs are independent literals in the Dutch written
// style (Taaladvies "8.30"), compared as UTF-8 bytes. The route is the one dictation runs:
// `InverseTextNormalizer.normalize(_:language:homeRegion:)` with the Dutch rule set.
//
// When this fails, a Dutch speaker's clock time stays as spoken words, or a duration, a quantity,
// the idiom "vijf voor twaalf" or ordinary prose is rewritten as a time.

@Suite("Dutch clock times (#1677)", .tags(.productOutcome))
struct LanguageDutchClockTests {

  private func normalized(_ text: String) throws -> String {
    let dutch = try #require(LanguageRuleRegistry.production.ruleSet(forLanguage: "nl"))
    return InverseTextNormalizer().normalize(text, language: dutch, homeRegion: "NL")
  }

  private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  @Test("measured engine shapes and real speech convert to the written time")
  func measuredShapes() throws {
    let cases: [(String, String)] = [
      // Real speech, both engines.
      (
        "Het is kwart over tien en ik ga nu naar huis rijden.",
        "Het is 10.15 en ik ga nu naar huis rijden."
      ),
      ("Het is nu 10 voor 11.", "Het is nu 10.50."),
      ("Het is nu tien voor elf.", "Het is nu 10.50."),
      ("Het is nu kwart voor negen.", "Het is nu 8.45."),
      (
        "Goedemorgen, het is vandaag dinsdag en het is tien over acht.",
        "Goedemorgen, het is vandaag dinsdag en het is 8.10."
      ),
      ("En ik heb die om half twee.", "En ik heb die om 1.30."),
      ("Oké, het is nu 10 voor half 2 en dat betekent", "Oké, het is nu 1.20 en dat betekent"),
      ("Oké, het is nu tien voor half twee.", "Oké, het is nu 1.20."),
      ("Oké, het is inmiddels tien voor zes avonds.", "Oké, het is inmiddels 5.50 avonds."),
      ("Ok, is inmiddels tien voor zes avonds.", "Ok, is inmiddels 5.50 avonds."),
      (
        "Ik heb mijn toets morgenochtend om kwart over elf.",
        "Ik heb mijn toets morgenochtend om 11.15."
      ),
      ("En misschien van kort of 10 tot half 4.", "En misschien van kort of 10 tot 3.30."),
      // Azure TTS through both engines.
      ("Ik kom om kwart voor acht.", "Ik kom om 7.45."),
      ("We beginnen om half negen.", "We beginnen om 8.30."),
      ("Het is tien over drie.", "Het is 3.10."),
      ("Ik bel je om tien over half negen.", "Ik bel je om 8.40."),
      ("Het is kwart over vijf.", "Het is 5.15."),
      // A capital after the time is a sentence start or a name in Dutch, not a noun gate.
      ("Het is kwart over tien En dan", "Het is 10.15 En dan"),
      // The article-shaped hour ends the phrase; an article after the time is not a number.
      ("We spreken af om kwart over een.", "We spreken af om 1.15."),
      ("Ik heb om half drie een afspraak.", "Ik heb om 2.30 een afspraak."),
      // A compound minute from the Dutch lexicon.
      ("Het is vijfentwintig over drie.", "Het is 3.25."),
    ]
    for (input, expected) in cases {
      #expect(bytes(try normalized(input)) == bytes(expected), "\(input)")
    }
  }

  @Test("idioms, durations, quantities and prose without a clock time stay as written")
  func controls() throws {
    let unchanged = [
      // The idiom "almost too late" (and its cost: 11:50 also stays as spoken).
      "Het is vijf voor twaalf voor het klimaat.", "Het is 5 voor 12.",
      "We vertrekken om tien voor twaalf.",
      // Durations and "over" meaning "in".
      "We hebben nog vijftien minuten.", "Dat betekent dat over 10 minuten mijn tentamen begint.",
      "Over een paar uur komt de video online.", "Een half uur later.", "Het glas is half vol.",
      "Het is half werk.", "Het duurt ten minste tien minuten.",
      // The article-shaped hour before a noun, a currency, a clock-face hour, a number continuation.
      "We zien elkaar om 5 over een week.", "We zien elkaar om 5 over 1 week.",
      "Het kost om 5 voor 3 euro.", "We eten om half een.",
      "Het was om 5 over 3 tweeëntwintig.",
      // No anchor, already written, hour-marker-minute forms (not in scope).
      "Tien over drie was de beste tijd.", "We zien elkaar om 8.30 uur.",
      "Ik zat op mijn kamer twee uur 's nachts.", "Het is nu 1 uur 39.",
      // A spoken operand before the plus word is a sum, not a phone number.
      "Reken uit: een plus 31 612 345 678.", "Twee plus 31 612 345 678 is veel.",
    ]
    for text in unchanged {
      #expect(bytes(try normalized(text)) == bytes(text), "\(text)")
    }
  }

  @Test("the Dutch grammar reads cardinals 0-59 from the generated lexicon")
  func dutchCardinals() throws {
    let parser = LanguageNumberParser(grammar: try LanguageNumberGrammar.dutch())
    func value(_ text: String) -> Int? {
      let snapshot = LanguageTextSnapshot(text)
      guard
        case .parsed(let number) = parser.parse(
          .cardinal, in: snapshot, range: 0..<snapshot.utf16Count)
      else { return nil }
      return number.value
    }
    let cases: [(String, Int)] = [
      ("nul", 0), ("een", 1), ("één", 1), ("twaalf", 12), ("negentien", 19), ("twintig", 20),
      ("eenentwintig", 21), ("tweeëntwintig", 22), ("drieëntwintig", 23), ("vijfenvijftig", 55),
      ("negenenvijftig", 59), ("twee\u{0065}\u{0308}ntwintig", 22), ("tweeën twintig", 22),
    ]
    for (text, expected) in cases {
      #expect(value(text) == expected, "\(text)")
    }
    for text in ["twee en twintig", "tweeentwintig", "honderd", "eerste", "vijf komma vijf"] {
      #expect(value(text) == nil, "\(text)")
    }
  }
}
