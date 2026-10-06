import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - The signed phone path in French, Spanish, Italian and Portuguese (#1677)
//
// Inputs are engine output measured on Azure TTS through Parakeet and WhisperKit (the spoken plus
// word kept before the digits, grouping chosen by the engine). Expected outputs are independent
// literals compared as UTF-8 bytes. These languages have no unsigned word classes, so a number
// without a plus word or sign is never touched.
//
// When this fails, an international number keeps its spoken plus word, loses a digit, or prose
// with the plus word is rewritten.

@Suite("Signed phone path in fr, es, it, pt (#1677)", .tags(.driftGuard))
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
      ("fr", "Vous pouvez me joindre au plus 33 612 34 56 78.", "Vous pouvez me joindre au +33 6 12 34 56 78."),
      ("fr", "Le numéro du bureau est le plus 331 42 68 15 23.", "Le numéro du bureau est le +33 1 42 68 15 23."),
      ("es", "Llámame al más 34612 34 56 78, por favor.", "Llámame al +34 612 34 56 78, por favor."),
      ("es", "Mi número es mas 34 612 34 56 78.", "Mi número es +34 612 34 56 78."),
      ("it", "Chiamami al più 39 347 1234567.", "Chiamami al +39 347 123 4567."),
      ("it", "Il numero è piu 39 06 4827 1935.", "Il numero è +39 06 4827 1935."),
      ("pt", "Ligue para mais 351 912 345 678.", "Ligue para +351 912 345 678."),
    ]
    for (language, input, expected) in cases {
      #expect(bytes(try converted(input, language: language)) == bytes(expected), "\(language): \(input)")
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
    ]
    for (language, text) in cases {
      #expect(bytes(try converted(text, language: language)) == bytes(text), "\(language): \(text)")
    }
  }

  @Test("only the four declared languages have signed-only phone rules")
  func declaredLanguages() throws {
    for code in ["fr", "es", "it", "pt"] {
      #expect(try LanguagePhonePrefixRules.signedOnly(language: code) != nil, "\(code)")
    }
    for code in ["de", "nl", "pl", "en"] {
      #expect(try LanguagePhonePrefixRules.signedOnly(language: code) == nil, "\(code)")
    }
  }
}
