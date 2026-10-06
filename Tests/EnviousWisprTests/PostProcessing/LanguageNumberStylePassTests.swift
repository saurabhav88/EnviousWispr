import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - The number-style pass (#1677)
//
// Drives the real pass and the real shared editor over engine-written German. Expected outputs
// are independent literals compared as UTF-8 bytes; each conversion is paired with a near input
// that must stay as written.
//
// When this fails, a unit word after a number stays a word, a postcode keeps its thousands dot,
// or a count, an amount or a date loses digits or formatting.

@Suite("German number-style pass (#1677)", .tags(.driftGuard))
struct LanguageNumberStylePassTests {

  let pass = LanguageNumberStylePass(rules: try! LanguageNumberStyleRules.german())

  private func converted(_ text: String) -> String {
    let snapshot = LanguageTextSnapshot(text)
    switch LanguageTextEditor.apply(pass.propose(in: snapshot), to: snapshot) {
    case .applied(let output): return output
    case .refused(let refusal):
      Issue.record("the editor refused the pass's own edits: \(refusal)")
      return text
    }
  }

  private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  @Test("a number followed by the word Prozent is written with the percent sign")
  func percentWord() {
    let cases: [(String, String)] = [
      ("Die Zustimmung sank auf 48 Prozent.", "Die Zustimmung sank auf 48%."),
      ("Die Quote liegt bei 3,5 Prozent.", "Die Quote liegt bei 3,5%."),
      ("Also 33 Prozent, fehlt noch.", "Also 33%, fehlt noch."),
      ("Rund 1.200 Prozent mehr.", "Rund 1.200% mehr."),
      ("(12 Prozent)", "(12%)"),
    ]
    for (input, expected) in cases {
      #expect(bytes(converted(input)) == bytes(expected), "\(input)")
    }
    for text in [
      "Die Zustimmung lag bei achtundvierzig Prozent.", "Das sind 48%.", "Es gab 48, Prozent.",
      "Ein Prozentsatz von 48 ist hoch.", "Version 2.5.0 Prozent", "Der Wert 48\nProzent",
    ] {
      #expect(bytes(converted(text)) == bytes(text), "\(text.debugDescription)")
    }
  }

  @Test("a dotted five-digit postcode loses its dot only after a street address or a postcode label")
  func postcodes() {
    let cases: [(String, String)] = [
      ("Meine Adresse ist Hauptstraße 12 10.115 Berlin.", "Meine Adresse ist Hauptstraße 12 10115 Berlin."),
      ("Hauptstraße 12, 10.115 Berlin", "Hauptstraße 12, 10115 Berlin"),
      ("Postleitzahl 50.667 Köln.", "Postleitzahl 50667 Köln."),
      ("Die PLZ 80.331 München, bitte.", "Die PLZ 80331 München, bitte."),
      ("Lindenallee 5a 01.067 Dresden", "Lindenallee 5a 01067 Dresden"),
    ]
    for (input, expected) in cases {
      #expect(bytes(converted(input)) == bytes(expected), "\(input)")
    }
    for text in [
      "Die Stadt hat 10.115 Einwohner.", "Hauptstraße 12 10.115 einwohner", "Wir zählen 50.667 Besucher.",
      "Am 05.05.2024 Berlin", "Hauptstraße 10.115 Berlin", "Haus 12 10.115 Berlin",
      "Postleitzahl 150.667 Köln", "Postleitzahl 10115 Berlin",
    ] {
      #expect(bytes(converted(text)) == bytes(text), "\(text)")
    }
  }

  @Test("a second pass proposes nothing, and money and dates stay as the engine wrote them")
  func idempotentAndNarrow() {
    let once = converted("Hauptstraße 12 10.115 Berlin, 48 Prozent.")
    #expect(once == "Hauptstraße 12 10115 Berlin, 48%.")
    #expect(pass.propose(in: LanguageTextSnapshot(once)).isEmpty)
    for text in ["Das kostet 19,99 Euro.", "Am 3. Oktober 2026.", "Es waren 1.200.000 Besucher."] {
      #expect(pass.propose(in: LanguageTextSnapshot(text)).isEmpty, "\(text)")
    }
  }
}
