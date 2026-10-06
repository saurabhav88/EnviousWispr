import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - The signed phone path in French, Spanish, Italian, Portuguese, Dutch, Polish, Swedish and
// Ukrainian (#1677)
//
// Inputs are engine output measured on Azure TTS through Parakeet and WhisperKit (the spoken plus
// word kept before the digits, grouping chosen by the engine). Expected outputs are independent
// literals compared as UTF-8 bytes. These languages have no unsigned word classes, so a number
// without a plus word or sign is never touched.
//
// When this fails, an international number keeps its spoken plus word, loses a digit, or prose
// with the plus word is rewritten.

@Suite("Signed phone path in fr, es, it, pt, nl, pl, sv, uk (#1677)", .tags(.driftGuard))
struct LanguagePhoneSignedLanguagesTests {

  private func converted(_ text: String, language: String) throws -> String {
    let rules = try #require(try LanguagePhonePrefixRules.signedOnly(language: language))
    let pass = LanguagePhonePrefixPass(grammar: nil, rules: rules)
    let snapshot = LanguageTextSnapshot(text)
    guard case .ran(let run) = pass.propose(in: snapshot, homeRegion: "FR") else {
      Issue.record("the pass reported itself unavailable")
      return text
    }
    switch LanguageTextEditor.apply(run.edits, to: snapshot) {
    case .applied(let output): return output
    case .refused(let refusal):
      Issue.record("the editor refused the pass's own edits: \(refusal)")
      return text
    }
  }

  private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  @Test("the measured engine shapes convert, every digit kept")
  func measuredShapes() throws {
    let cases: [(String, String, String)] = [
      (
        "fr", "Vous pouvez me joindre au plus 33 612 34 56 78.",
        "Vous pouvez me joindre au +33 6 12 34 56 78."
      ),
      (
        "fr", "Le numéro du bureau est le plus 331 42 68 15 23.",
        "Le numéro du bureau est le +33 1 42 68 15 23."
      ),
      (
        "es", "Llámame al más 34612 34 56 78, por favor.", "Llámame al +34 612 34 56 78, por favor."
      ),
      ("es", "Mi número es mas 34 612 34 56 78.", "Mi número es +34 612 34 56 78."),
      ("it", "Chiamami al più 39 347 1234567.", "Chiamami al +39 347 123 4567."),
      ("it", "Il numero è piu 39 06 4827 1935.", "Il numero è +39 06 4827 1935."),
      ("pt", "Ligue para mais 351 912 345 678.", "Ligue para +351 912 345 678."),
      // Dutch and Polish (both engines keep the plus word; WhisperKit writes Polish "PLUS").
      ("nl", "Mijn nummer is plus 31 6 12 34 56 78.", "Mijn nummer is +31 6 12345678."),
      // 61 is the Poznań area code: libphonenumber writes the landline "+48 61 234 56 78".
      ("pl", "Mój numer to plus 48 612 345 678.", "Mój numer to +48 61 234 56 78."),
      ("pl", "Mój numer to PLUS 48 612 345 678.", "Mój numer to +48 61 234 56 78."),
      ("pl", "Zadzwoń na plus 48 501 234 567.", "Zadzwoń na +48 501 234 567."),
      // Swedish and Ukrainian (libphonenumber grouping).
      ("sv", "Mitt nummer är plus 46 70 123 45 67.", "Mitt nummer är +46 70 123 45 67."),
      ("uk", "Мій номер плюс 380 67 123 45 67.", "Мій номер +380 67 123 4567."),
    ]
    for (language, input, expected) in cases {
      #expect(
        bytes(try converted(input, language: language)) == bytes(expected), "\(language): \(input)")
    }
  }

  @Test("prose with the plus word, arithmetic, quantities and unsigned numbers stay as written")
  func controls() throws {
    let cases: [(String, String)] = [
      ("fr", "Il y a plus de 30 personnes."), ("fr", "Il en faut plus 3 ou 4."),
      ("fr", "Mon portable est le 06 12 34 56 78."), ("fr", "Appelle le 33 6 12 34 56 78."),
      ("es", "Dos más tres son cinco: 2 más 3."), ("es", "Necesitamos más 20 sillas."),
      ("it", "Siamo più di 50 persone."), ("it", "Servono più 5 euro."),
      ("pt", "Mais 20 minutos e chegamos."), ("pt", "Ligue para 912 345 678."),
      // Large amounts after the plus word: thousands grouping, with and without a money word.
      ("pt", "Precisamos de mais 1.000.000 reais."), ("pt", "São mais 1.000.000 de pessoas."),
      ("fr", "Il y a plus 1 000 000 d'habitants."), ("es", "Son más 2.500.000 personas."),
      ("it", "Servono più 1.000.000 euro."), ("es", "Cuesta más 34 612 345 678 pesos."),
      ("nl", "Morgen wordt het plus 20 graden."), ("nl", "Je doet 1 plus 1, dat is 2."),
      ("nl", "Bel me op 06 12 34 56 78."), ("pl", "Jutro będzie plus 20 stopni."),
      ("pl", "Dwa plus dwa to 4: 2 plus 2."), ("pl", "Zadzwoń pod numer 501 234 567."),
      ("sv", "I morgon blir det plus 20 grader."), ("sv", "Två plus 2 är 4."),
      ("uk", "Завтра буде плюс 20 градусів."), ("uk", "Два плюс 2 дорівнює 4."),
      ("pl", "To kosztuje plus 48 501 234 567 PLN."), ("pl", "Razem plus 48 501 234 567 złotych."),
    ]
    for (language, text) in cases {
      #expect(bytes(try converted(text, language: language)) == bytes(text), "\(language): \(text)")
    }
  }

  @Test("only the eight declared languages have signed-only phone rules")
  func declaredLanguages() throws {
    for code in ["fr", "es", "it", "pt", "nl", "pl", "sv", "uk"] {
      #expect(try LanguagePhonePrefixRules.signedOnly(language: code) != nil, "\(code)")
    }
    for code in ["de", "ru", "fi", "en"] {
      #expect(try LanguagePhonePrefixRules.signedOnly(language: code) == nil, "\(code)")
    }
  }
}
