import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - Hour-first clock times in French, Spanish, Italian and Portuguese (#1677)
//
// Inputs are engine output measured on Azure TTS through Parakeet and WhisperKit
// (docs/audits/2026-10-06-1677-{fr,es,it,pt}-shapes, clock rows), plus prose controls. Expected
// outputs are independent literals compared as UTF-8 bytes.
//
// When this fails, a spoken clock time in one of these languages is not written as a time, or a
// count, a duration or a pair of numbers is rewritten as one.

@Suite("Hour-first clock times in fr, es, it, pt (#1677)", .tags(.productOutcome))
struct LanguageHourFirstClockPassTests {

  private func converted(_ text: String, language: String) throws -> String {
    let rules = try #require(LanguageHourFirstClockRules(language: language))
    let pass = LanguageHourFirstClockPass(rules: rules)
    let snapshot = LanguageTextSnapshot(text)
    guard case .ran(let edits) = pass.propose(in: snapshot) else {
      Issue.record("the pass reported itself unavailable")
      return text
    }
    switch LanguageTextEditor.apply(edits, to: snapshot) {
    case .applied(let output): return output
    case .refused(let refusal):
      Issue.record("the editor refused the pass's own edits: \(refusal)")
      return text
    }
  }

  private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

  @Test("the measured engine shapes become written times; every other byte stays")
  func measuredShapes() throws {
    let cases: [(String, String, String)] = [
      // Spanish
      (
        "es", "La reunión empieza a las siete y media de la tarde.",
        "La reunión empieza a las 7:30 de la tarde."
      ),
      ("es", "Nos vemos a las 8 y cuarto de la mañana.", "Nos vemos a las 8:15 de la mañana."),
      ("es", "El tren sale a las 9 menos cuarto.", "El tren sale a las 8:45."),
      ("es", "La consulta termina a la una y media.", "La consulta termina a la 1:30."),
      ("es", "Recógeme a las 10 menos 20.", "Recógeme a las 9:40."),
      ("es", "Llegaré sobre las 5 menos 5.", "Llegaré sobre las 4:55."),
      (
        "es", "Tenemos mesa reservada para las 2 y cuarto.", "Tenemos mesa reservada para las 2:15."
      ),
      ("es", "En Lima quedamos a un cuarto para las 8.", "En Lima quedamos a las 7:45."),
      ("es", "En México salimos a 20 para las 6.", "En México salimos a las 5:40."),
      ("es", "Son las 3 y media.", "Son las 3:30."),
      // Italian
      ("it", "Ci vediamo alle 7 e mezza!", "Ci vediamo alle 7:30!"),
      ("it", "Il treno parte alle otto e mezzo.", "Il treno parte alle 8:30."),
      ("it", "La riunione comincia alle 9 e un quarto.", "La riunione comincia alle 9:15."),
      ("it", "Passo da te alle 10 e 3 quarti.", "Passo da te alle 10:45."),
      ("it", "Passo da te alle 10 e tre quarti.", "Passo da te alle 10:45."),
      ("it", "Il negozio chiude alle 6 meno un quarto.", "Il negozio chiude alle 5:45."),
      ("it", "Arrivo alle 4 meno 5.", "Arrivo alle 3:55."),
      ("it", "Pranziamo all'una e mezza.", "Pranziamo all'1:30."),
      (
        "it", "La consegna è prevista per mezzogiorno e un quarto.",
        "La consegna è prevista per 12:15."
      ),
      ("it", "Il film finisce a mezzanotte e mezzo.", "Il film finisce a 0:30."),
      // Portuguese
      ("pt", "A reunião começa às sete e meia.", "A reunião começa às 7h30."),
      (
        "pt", "A consulta ficou marcada para as 10 e 1 quarto.",
        "A consulta ficou marcada para as 10h15."
      ),
      (
        "pt", "A consulta ficou marcada para as 10 e um quarto.",
        "A consulta ficou marcada para as 10h15."
      ),
      ("pt", "Chego às 9 menos 1 quarto.", "Chego às 8h45."),
      ("pt", "Chego às 9 menos um quarto.", "Chego às 8h45."),
      ("pt", "O filme começa a um quarto para as 10.", "O filme começa a um quarto para as 10."),
      ("pt", "Encontramos-nos às 3 menos 10.", "Encontramos-nos às 2h50."),
      ("pt", "O autocarro passa às 20 para as 4.", "O autocarro passa às 3h40."),
      ("pt", "O autocarro passa às 20 para às 4.", "O autocarro passa às 3h40."),
      ("pt", "O almoço começa à uma e meia.", "O almoço começa à 1h30."),
      // French
      ("fr", "Je passerai vers 8h moins le quart.", "Je passerai vers 7h45."),
      ("fr", "Je passerai vers 8 heures moins le quart.", "Je passerai vers 7h45."),
      ("fr", "Le rendez-vous est à 10h moins 10.", "Le rendez-vous est à 9h50."),
      ("fr", "Nous déjeunerons à midi et quart.", "Nous déjeunerons à 12h15."),
      ("fr", "Le dernier bus passe à minuit et demi.", "Le dernier bus passe à 0h30."),
      (
        "fr", "On se retrouve à sept heures et demie devant la gare.",
        "On se retrouve à 7h30 devant la gare."
      ),
    ]
    for (language, input, expected) in cases {
      #expect(
        bytes(try converted(input, language: language)) == bytes(expected), "\(language): \(input)")
    }
  }

  @Test("counts, durations, number pairs, engine errors and already-written times stay as written")
  func controls() throws {
    let cases: [(String, String)] = [
      // Hour + connector + DIGIT minutes is also a pair of numbers.
      ("es", "Envía el aviso a las 6 y 10 de la lista."), ("es", "La clase empieza a las 6 y 10."),
      ("it", "Rispondi alle 5 e 10 del questionario."), ("it", "La visita è alle 5 e 10."),
      ("pt", "Distribui 20 para as 4 e guarda o resto."),
      // Durations and missing anchors.
      ("fr", "Réserve une table pour une heure et demie."), ("es", "Necesito siete y media horas."),
      ("es", "Dame tres y media."), ("it", "Ne servono tre e mezza."),
      // Engine errors and times the engine already wrote.
      ("it", "Arrivo alle 4-5."), ("it", "Il negozio chiude alle 6-1 quarto."),
      ("it", "La visita è alle 5.10."),
      ("fr", "Le rendez-vous est à 10h-10."), ("pt", "O comboio sai às 8h14."),
      ("fr", "Le cours commence à 9h15."),
      ("pt", "A loja abre às 9h15."), ("fr", "Je passerai vers 8 moins le quart."),
      // A clock-face choice, a number or unit continuing, punctuation inside the idiom.
      ("es", "Quedamos a la una menos cuarto."), ("es", "Son las 3 y media 4 veces."),
      ("es", "Cuesta a las 3 y media euros."), ("es", "A las 9, menos cuarto."),
    ]
    for (language, text) in cases {
      #expect(bytes(try converted(text, language: language)) == bytes(text), "\(language): \(text)")
    }
  }

  @Test("only the four declared languages have hour-first clock rules")
  func declaredLanguages() {
    for code in ["fr", "es", "it", "pt"] {
      #expect(LanguageHourFirstClockRules(language: code) != nil, "\(code)")
    }
    for code in ["de", "nl", "pl", "en"] {
      #expect(LanguageHourFirstClockRules(language: code) == nil, "\(code)")
    }
  }
}
