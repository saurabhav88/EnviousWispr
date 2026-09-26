import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// German, Russian, Portuguese and Italian spoken addresses, links and codes convert on a take the
/// app resolved as non-English (#3233).
///
/// **When this fails, a German speaker who says "beispiel Punkt de Schrägstrich hilfe" pastes the
/// words, or an ordinary sentence ("A barra de metal caiu.") turns into a link.** Product coverage.
/// Expected outputs are written by hand. "Perfect hearing" rows are the sentences as a recogniser
/// writes them when every word is heard (or repaired by the custom dictionary); the WhisperKit rows
/// are verbatim output for Azure clips with the language set
/// (`docs/audits/2026-09-26-3233-baseline-azure/`, main checkout).
@Suite(
  "ITN converts German, Russian, Portuguese and Italian addresses (#3233)", .tags(.productOutcome))
struct InverseTextNormalizerNeutralAddressesMoreLanguagesTests {

  private func neutral(_ s: String) -> String {
    InverseTextNormalizer().normalizeLanguageNeutral(s)
  }

  nonisolated static let rows: [(dictated: String, expected: String)] = [
    // German, perfect hearing (nouns capitalised as the recogniser writes them)
    (
      "auf der Website www Punkt beispiel Punkt de, einschließlich",
      "auf der Website www.beispiel.de, einschließlich"
    ),
    (
      "öffne die Seite beispiel Punkt de Schrägstrich hilfe und folge",
      "öffne die Seite beispiel.de/hilfe und folge"
    ),
    (
      "ein, https Doppelpunkt Schrägstrich Schrägstrich beispiel Punkt de, damit",
      "ein, https://beispiel.de, damit"
    ),
    ("läuft er auf localhost Doppelpunkt 3000, und du", "läuft er auf localhost:3000, und du"),
    ("die Seite we we we Punkt beispiel Punkt de heute", "die Seite www.beispiel.de heute"),
    // Russian, perfect hearing
    ("установила версию 2 точка 5 точка 0 приложения", "установила версию 2.5.0 приложения"),
    ("адрес 192 точка 168 точка 1 точка 1 и введи", "адрес 192.168.1.1 и введи"),
    ("движок исправлений S дефис 1, потому что", "движок исправлений S-1, потому что"),
    ("модель GPT дефис 4 кратко", "модель GPT-4 кратко"),
    ("указан номер B тире 2, поэтому", "указан номер B-2, поэтому"),
    (
      "отправь письмо на info собака yandex точка ру с датой",
      "отправь письмо на info@yandex.ru с датой"
    ),
    ("теперь это olga собака mail точка ру, так что", "теперь это olga@mail.ru, так что"),
    ("на сайте www точка example точка ру, включая", "на сайте www.example.ru, включая"),
    (
      "открой страницу example точка ру слэш help и выполни",
      "открой страницу example.ru/help и выполни"
    ),
    (
      "клиентам, https двоеточие слэш слэш example точка ру, чтобы",
      "клиентам, https://example.ru, чтобы"
    ),
    ("работает на localhost двоеточие 3000, и его", "работает на localhost:3000, и его"),
    ("сайт вэ вэ вэ точка example точка ру сегодня", "сайт www.example.ru сегодня"),
    ("страница example точка ру косая черта help и", "страница example.ru/help и"),
    // Portuguese, perfect hearing
    (
      "mensagem para contato arroba empresa ponto com ponto br com a data",
      "mensagem para contato@empresa.com.br com a data"
    ),
    ("no site www ponto exemplo ponto pt, incluindo", "no site www.exemplo.pt, incluindo"),
    (
      "abre a página exemplo ponto pt barra ajuda e segue", "abre a página exemplo.pt/ajuda e segue"
    ),
    (
      "clientes, https dois pontos barra barra exemplo ponto com ponto br, para",
      "clientes, https://exemplo.com.br, para"
    ),
    ("ele corre em localhost dois pontos 3000 e podes", "ele corre em localhost:3000 e podes"),
    ("agora é inês arroba exemplo ponto pt, por isso", "agora é inês@exemplo.pt, por isso"),
    // Italian, perfect hearing (`.it` after `punto` or a written dot)
    (
      "manda un messaggio a info chiocciola azienda punto it con la data",
      "manda un messaggio a info@azienda.it con la data"
    ),
    ("adesso è niccolò chiocciola esempio punto it, quindi", "adesso è niccolò@esempio.it, quindi"),
    ("sul sito www punto esempio punto it, compresa", "sul sito www.esempio.it, compresa"),
    (
      "apri la pagina esempio punto it barra aiuto e segui",
      "apri la pagina esempio.it/aiuto e segui"
    ),
    (
      "clienti, https due punti barra barra esempio punto it, così",
      "clienti, https://esempio.it, così"
    ),
    ("funziona su localhost due punti 3000 e puoi", "funziona su localhost:3000 e puoi"),
    ("la pagina esempio.it barra obliqua aiuto e", "la pagina esempio.it/aiuto e"),
    // the Italian full slash name is read whole, whichever row's host precedes it
    ("abre ejemplo.es barra obliqua ayuda y", "abre ejemplo.es/ayuda y"),
    // a path segment that is itself the second word of the full slash name
    ("apri esempio.it barra obliqua obliqua oggi", "apri esempio.it/obliqua oggi"),
    // a domain the recogniser already dotted, licensed by the language's own address word
    ("manda un messaggio a info chiocciola azienda.it oggi", "manda un messaggio a info@azienda.it oggi"),
    ("отправь письмо на info собака yandex.ru сегодня", "отправь письмо на info@yandex.ru сегодня"),
    ("mande uma mensagem para contato arroba empresa.com.br hoje", "mande uma mensagem para contato@empresa.com.br hoje"),
    // WhisperKit, language set: verbatim (#3233 baseline v1)
    (
      "Se il programma non si avvia, apri la pagina esempio.it barra aiuto e segui i passaggi nella sezione dei problemi frequenti.",
      "Se il programma non si avvia, apri la pagina esempio.it/aiuto e segui i passaggi nella sezione dei problemi frequenti."
    ),
    (
      "Se hai domande sulla fattura, scrivi direttamente a marco.rossichiocciolagmail.com e ti risponderai in giornata.",
      "Se hai domande sulla fattura, scrivi direttamente a marco.rossi@gmail.com e ti risponderai in giornata."
    ),
    (
      "Per prenotare la sala riunioni, manda un messaggio a infochiocciolaazienda.it con la data e il numero dei partecipanti.",
      "Per prenotare la sala riunioni, manda un messaggio a info@azienda.it con la data e il numero dei partecipanti."
    ),
    (
      "Para reservar a sala de reuniões, mande uma mensagem para contato arrobaempresa.com.br com a data e o número de participantes.",
      "Para reservar a sala de reuniões, mande uma mensagem para contato@empresa.com.br com a data e o número de participantes."
    ),
    (
      "Чтобы забронировать переговорную, отправь письмо на info.собака.yandex.ru с датой и числом участников.",
      "Чтобы забронировать переговорную, отправь письмо на info@yandex.ru с датой и числом участников."
    ),
  ]

  @Test("converts the whole address, link or code", arguments: rows)
  func row(row: (dictated: String, expected: String)) {
    #expect(neutral(row.dictated) == row.expected)
  }

  /// Ordinary sentences that carry a new word, and near misses that must not half-convert. Every
  /// one must come back byte-identical.
  nonisolated static let controls: [String] = [
    // the baseline's everyday sentences
    "Der wichtigste Punkt in der Diskussion war die knappe Zeit.",
    "Zieh einen Strich unter die wichtigen Wörter und setz nach dem Doppelpunkt eine Erklärung.",
    "Wir sind 300 Leute auf der Konferenz, und der große Saal öffnet um halb 10.",
    "Собака спокойно спала возле двери, пока мы обсуждали расписание.",
    "Поставь точку в конце предложения, а между частями фразы поставь тире.",
    "На конференции будет 300 человек.",
    "O ponto principal da conversa foi o prazo curto, e a equipa ganhou dois pontos.",
    "A barra de metal caiu durante a mudança e vejo um traço pequeno no papel.",
    "Vamos ser 300 pessoas no congresso, e a sala abre às 9h30.",
    "Questo punto della discussione richiede attenzione, e la squadra ha segnato due punti.",
    "La chiocciola attraversò lentamente il giardino mentre la barra di ferro si piegava.",
    "Saremo 300 persone al congresso.",
    // G1: link words outside a link
    "Das ist ein wichtiger Punkt, und Punkt de ist ein Kürzel.",
    "Zieh einen Schrägstrich durch die Zahl.",
    "Nach dem Doppelpunkt kommt die Liste.",
    "Собака лает, точка.",
    "Поставь точку и слэш в конце строки.",
    "Ganhámos dois pontos.",
    "Abbiamo due punti di vantaggio.",
    "la barra obliqua sul foglio",
    "Vediamo il punto it della questione.",
    // G1: a link that goes on in a spoken question mark stays whole
    "öffne beispiel Punkt de Schrägstrich hilfe Fragezeichen q gleich 1",
    "открой example точка ру слэш help вопросительный знак q",
    "abre exemplo ponto pt barra ajuda ponto de interrogação q",
    "apri esempio punto it barra aiuto punto interrogativo q",
    "läuft auf localhost Doppelpunkt 3000 Fragezeichen q",
    // a dot word that begins a spoken question mark is not a dot (cloud review, PR #3235)
    "https dois pontos barra barra exemplo ponto pt ponto de interrogação q",
    "escreva a ana arroba exemplo ponto pt ponto de interrogação q",
    "https due punti barra barra esempio punto it punto interrogativo q",
    // any language's question mark after a `www` alias with written dots
    "we we we.example.de Fragezeichen q",
    "вэ вэ вэ.example.ru вопросительный знак q",
    "адрес 192 точка 168 точка 1 точка 1 вопросительный знак q",
    // G2: `.it` never after the English `dot`; `.com.br` only whole
    "scrivi a marco chiocciola esempio dot it",
    "scrivi a john.smith at example dot it",
    "contato arroba empresa ponto com ponto br ponto xyz",
    // G3: `ру` only after `точка`, only as the last label
    "info собака yandex punto ру",
    "www punto example punto ру",
    "example точка ру точка xyz",
    "www точка example точка ру точка com",
    "письмо на info собака yandex точка ру точка com",
    "письмо на info.собака.yandex.ру.com",
    "открой example точка ру точка com слэш help",
    "Это ру",
    // G4: a single `точка` or dash word between digits is prose
    "Команда получила 2 точка",
    "версия 2 точка 5 точка",
    "Здесь нужно тире 2",
    // G6: plural and inflected near misses, and glued words with no address cue
    "Le chiocciole sono lente.",
    "compramos três arrobas de café",
    "a mensagem diz três arrobasdecafe.com.br",
    "La foto infochiocciolaazienda.it era bella.",
    "Мы видели info.собака.yandex.ru на экране.",
    "отправь письмо на info.собака.yandex.ру сегодня",
    "Il mio indirizzo è cambiato. Adesso è niccolocchiocciolaesempio.it, quindi aggiorna la rubrica.",
    // G7: the name was not heard
    "напиши на собака gmail точка com",
    "scrivi alla chiocciola esempio punto it",
    "escreva ao arroba exemplo ponto pt",
    "mande uma mensagem para que arrobaexemplo.pt",
    "mande uma mensagem para que arroba empresa.com.br hoje",
    // a line break ends a number
    "versão 2 ponto\n5 ponto 0",
    "версия 2 точка\n5 точка 0",
    "La chiocciola azienda.it era scritta sul muro.",
    // G7: a one-word mailbox in another language still converts (checked in `rows` of #3226)
  ]

  @Test("what must not move", arguments: controls)
  func control(text: String) {
    #expect(neutral(text) == text)
  }

  /// G7 refusals belong to their own language: the same word as a Spanish or Polish mailbox name
  /// still converts.
  nonisolated static let otherLanguageNames: [(dictated: String, expected: String)] = [
    ("escribe a que arroba ejemplo punto es", "escribe a que@ejemplo.es"),
    ("napisz do il małpa przykład kropka pl", "napisz do il@przykład.pl"),
    ("mi correo es que arrobaejemplo.es", "mi correo es que@ejemplo.es"),
  ]

  @Test("a refusal in one language never refuses another's mailbox", arguments: otherLanguageNames)
  func otherLanguageName(row: (dictated: String, expected: String)) {
    #expect(neutral(row.dictated) == row.expected)
  }

  @Test("one pass is enough: a second pass over the output changes nothing")
  func idempotent() {
    for row in Self.rows {
      let once = neutral(row.dictated)
      #expect(neutral(once) == once, "\(row.dictated)")
    }
  }

  /// The English route never reads the new words.
  nonisolated static let englishRouteUnchanged: [String] = [
    "beispiel Punkt de Schrägstrich hilfe", "2 точка 5 точка 0", "GPT дефис 4",
    "info собака yandex точка ру", "esempio.it barra aiuto", "infochiocciolaazienda.it",
    "contato arrobaempresa.com.br", "localhost due punti 3000", "he pointed at the dot it made",
  ]

  @Test("the English route leaves the new words alone", arguments: englishRouteUnchanged)
  func englishRoute(text: String) {
    #expect(InverseTextNormalizer().normalize(text, spokenPunctuation: false) == text)
  }
}
