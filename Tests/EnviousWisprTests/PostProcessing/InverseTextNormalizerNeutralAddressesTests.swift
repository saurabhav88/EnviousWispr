import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// French, Spanish, Polish and Dutch spoken addresses, links and codes convert on a take the app
/// resolved as non-English (#3226).
///
/// **When this fails, a Spanish speaker who says "ejemplo punto es barra ayuda" pastes the words,
/// or an ordinary sentence ("Tomamos algo en la barra del bar.") turns into a link.** Product
/// coverage. Expected outputs are written by hand. The "perfect hearing" rows are the sentences
/// as a recogniser writes them when every word is heard (or repaired by the custom dictionary);
/// the recogniser rows are verbatim WhisperKit (language set) and Parakeet output for Azure clips
/// (`docs/audits/2026-09-26-intl-codes-baseline-azure/`, main checkout).
@Suite("ITN converts French, Spanish, Polish and Dutch addresses (#3226)", .tags(.productOutcome))
struct InverseTextNormalizerNeutralAddressesTests {

  private func neutral(_ s: String) -> String {
    InverseTextNormalizer().normalizeLanguageNeutral(s)
  }

  nonisolated static let rows: [(dictated: String, expected: String)] = [
    // French, perfect hearing
    ("Écris à jean point dupont arobase gmail point com et", "Écris à jean.dupont@gmail.com et"),
    (
      "c'est maintenant hélène arobase exemple point fr, alors",
      "c'est maintenant hélène@exemple.fr, alors"
    ),
    ("sur le site www point exemple point fr, y compris", "sur le site www.exemple.fr, y compris"),
    (
      "ouvre la page exemple point fr barre oblique aide et suis",
      "ouvre la page exemple.fr/aide et suis"
    ),
    (
      "le lien https deux points barre oblique barre oblique exemple point fr, pour",
      "le lien https://exemple.fr, pour"
    ),
    ("il tourne sur localhost deux points 3000, et", "il tourne sur localhost:3000, et"),
    ("la référence B trait d'union 2, donc", "la référence B-2, donc"),
    ("la version 2 point 5 point 0 de", "la version 2.5.0 de"),
    // Spanish, perfect hearing
    ("escribe a maría punto lópez arroba gmail punto com y", "escribe a maría.lópez@gmail.com y"),
    (
      "manda un correo a recepción arroba empresa punto es con",
      "manda un correo a recepción@empresa.es con"
    ),
    ("la página www punto ejemplo punto es, incluido", "la página www.ejemplo.es, incluido"),
    ("abre ejemplo punto es barra ayuda y sigue", "abre ejemplo.es/ayuda y sigue"),
    (
      "el enlace https dos puntos barra barra ejemplo punto es, para",
      "el enlace https://ejemplo.es, para"
    ),
    ("funciona en localhost dos puntos 3000 y", "funciona en localhost:3000 y"),
    // a spoken http stays http
    ("el enlace http dos puntos barra barra ejemplo punto es barra ayuda.", "el enlace http://ejemplo.es/ayuda."),
    ("el modelo GPT guion 4 podría", "el modelo GPT-4 podría"),
    // Polish, perfect hearing
    ("wersję 2 kropka 5 kropka 0 aplikacji", "wersję 2.5.0 aplikacji"),
    ("adres 192 kropka 168 kropka 1 kropka 1 i", "adres 192.168.1.1 i"),
    ("silnik korekty S myślnik 1, bo", "silnik korekty S-1, bo"),
    ("model GPT łącznik 4 mógłby", "model GPT-4 mógłby"),
    ("oznaczenie B kreska 2, więc", "oznaczenie B-2, więc"),
    ("adres jan kropka kowalski małpa gmail kropka com, a", "adres jan.kowalski@gmail.com, a"),
    ("teraz to łukasz małpa przykład kropka pl, więc", "teraz to łukasz@przykład.pl, więc"),
    ("na stronie www kropka przykład kropka pl, razem", "na stronie www.przykład.pl, razem"),
    ("otwórz stronę przykład kropka pl ukośnik pomoc i", "otwórz stronę przykład.pl/pomoc i"),
    (
      "link https dwukropek ukośnik ukośnik przykład kropka pl, żeby",
      "link https://przykład.pl, żeby"
    ),
    ("działa on na localhost dwukropek 3000 i", "działa on na localhost:3000 i"),
    // Dutch, perfect hearing
    ("versie 2 punt 5 punt 0 van", "versie 2.5.0 van"),
    ("het adres 192 punt 168 punt 1 punt 1 in", "het adres 192.168.1.1 in"),
    ("de correctiemotor S streepje 1 gekozen", "de correctiemotor S-1 gekozen"),
    ("het model GPT streepje vier de notulen", "het model GPT-4 de notulen"),
    ("het kenmerk B koppelteken 2, dus", "het kenmerk B-2, dus"),
    (
      "mail naar jan punt jansen apenstaartje gmail punt com en",
      "mail naar jan.jansen@gmail.com en"
    ),
    ("het is nu anaïs apenstaartje voorbeeld punt nl, dus", "het is nu anaïs@voorbeeld.nl, dus"),
    ("de website www punt voorbeeld punt nl, inclusief", "de website www.voorbeeld.nl, inclusief"),
    ("Ga naar: www punt voorbeeld punt nl.", "Ga naar: www.voorbeeld.nl."),
    ("open dan voorbeeld punt nl schuine streep help en", "open dan voorbeeld.nl/help en"),
    (
      "link https dubbele punt schuine streep schuine streep voorbeeld punt nl, zodat",
      "link https://voorbeeld.nl, zodat"
    ),
    ("draait die op localhost dubbele punt 3000 en", "draait die op localhost:3000 en"),
    // French `point` is also English: a spoken www address converts on a take with no verdict
    ("Go to www point example point com now.", "Go to www.example.com now."),
    // a link converts whole: spoken www in each language, localhost with a port, a glued Dutch
    // path inside a protocol link (local Codex diff review r2 and its class enumeration)
    (
      "https dubbele punt schuine streep schuine streep voorbeeld punt nl schuine streephelp",
      "https://voorbeeld.nl/help"
    ),
    ("w w w punto ejemplo punto es barra ayuda", "www.ejemplo.es/ayuda"),
    ("wu wu wu kropka przykład kropka pl ukośnik pomoc", "www.przykład.pl/pomoc"),
    ("https dos puntos barra barra w w w punto ejemplo punto es", "https://www.ejemplo.es"),
    (
      "https dos puntos barra barra uve doble uve doble uve doble punto ejemplo punto es barra ayuda",
      "https://www.ejemplo.es/ayuda"
    ),
    ("localhost dos puntos 3000 barra api", "localhost:3000/api"),
    ("http dos puntos barra barra localhost dos puntos 3000", "http://localhost:3000"),
    ("localhost dwukropek 3000 ukośnik api ukośnik v1", "localhost:3000/api/v1"),
    ("triple w punto ejemplo punto es", "www.ejemplo.es"),
    // a spoken hyphen joins a name or domain; an IP address is a link host (local Codex class
    // enumeration, run against the branch)
    ("écris à jean trait d'union dupont arobase gmail point com", "écris à jean-dupont@gmail.com"),
    ("escribe a juan guion pérez arroba gmail punto com", "escribe a juan-pérez@gmail.com"),
    ("mail naar jan streepje jansen apenstaartje gmail punt com", "mail naar jan-jansen@gmail.com"),
    ("escribe a info arroba mi guion empresa punto es hoy", "escribe a info@mi-empresa.es hoy"),
    ("http dos puntos barra barra 192 punto 168 punto 1 punto 1 barra api", "http://192.168.1.1/api"),
    // the recogniser joined `www` to the next label and left the last dot spoken (diff review r3)
    ("ga naar www.voorbeeld punt nl vandaag", "ga naar www.voorbeeld.nl vandaag"),
    // `localhost` is a host only on its own: a domain starting with the word keeps its ending (r4)
    ("http dos puntos barra barra localhost punto com", "http://localhost.com"),
    // a host the recogniser wrote keeps its case when a spoken path joins it (cloud review)
    ("Abre Ejemplo.ES barra ayuda", "Abre Ejemplo.ES/ayuda"),
    // only spoken separators change: every word keeps the case the recogniser wrote, as on the
    // English route (cloud review class enumeration)
    ("Escribe a María.López arroba Mi-Empresa.COM", "Escribe a María.López@Mi-Empresa.COM"),
    ("Ouvre HTTPS deux points barre oblique barre oblique Éxemple point FR", "Ouvre HTTPS://Éxemple.FR"),
    ("Visit WWW.Example punto COM now", "Visit WWW.Example.COM now"),
    // German borrowed "at"; a Unicode name
    ("schreib an müller at beispiel punkt de bitte", "schreib an müller@beispiel.de bitte"),
    // recogniser output, verbatim
    ("Klient zapytał, czy model GPT Łącznik 4 mógłby", "Klient zapytał, czy model GPT-4 mógłby"),
    (
      "De klant vroeg of het model GPT-streepje vier de notule",
      "De klant vroeg of het model GPT-4 de notule"
    ),
    ("Het pakket heeft het kenmerk B-koppelteken 2, dus", "Het pakket heeft het kenmerk B-2, dus"),
    (
      "Le colis porte la référence B-Trait d'Union 2, donc", "Le colis porte la référence B-2, donc"
    ),
    ("wybrałem silnik korekty S-myślnik 1, bo", "wybrałem silnik korekty S-1, bo"),
    // a lower-case spelled letter glued to the dash word reads like the separate form (r7)
    ("de motor s-streepje vier is snel", "de motor S-4 is snel"),
    (
      "Si el programa no arranca, abre ejemplo.es barra ayuda y",
      "Si el programa no arranca, abre ejemplo.es/ayuda y"
    ),
    ("otwórz stronę przykład.pl ukośnik Pomoc i", "otwórz stronę przykład.pl/Pomoc i"),
    ("Ouvre la page exemple.fr bar oblique aide et", "Ouvre la page exemple.fr/aide et"),
    ("open dan voorbeeld.nl schuine streephelp en", "open dan voorbeeld.nl/help en"),
    (
      "manda un correo a recepción arroba empresa.es con",
      "manda un correo a recepción@empresa.es con"
    ),
    (
      "Mój prywatny adres się zmienił. Teraz to Łukasz małpa, przykład.pl, więc",
      "Mój prywatny adres się zmienił. Teraz to Łukasz@przykład.pl, więc"
    ),
    (
      "mail dan rechtstreeks naar jan.jansenapenstaartje gmail.com en",
      "mail dan rechtstreeks naar jan.jansen@gmail.com en"
    ),
    (
      "stuur je een bericht naar receptieapenstaartjebedrijf.nl met",
      "stuur je een bericht naar receptie@bedrijf.nl met"
    ),
    (
      "Mijn privéadres is veranderd. Het is nu anaisapenstaartjevoorbeeld.nl, dus",
      "Mijn privéadres is veranderd. Het is nu anais@voorbeeld.nl, dus"
    ),
    // a canonically decomposed accent stays decomposed; bytes outside the address are untouched
    ("Mi correo es jose\u{301} arroba ejemplo punto es.", "Mi correo es jose\u{301}@ejemplo.es."),
  ]

  @Test("converts the whole address, link or code", arguments: rows)
  func row(row: (dictated: String, expected: String)) {
    #expect(neutral(row.dictated) == row.expected)
  }

  /// Ordinary sentences in each language that carry a new word, and near-misses that must not
  /// half-convert. Every one must come back byte-identical.
  nonisolated static let controls: [String] = [
    // the baseline's everyday sentences
    "C'est un bon point que tu soulèves, mais de mon point de vue il faut d'abord finir le projet.",
    "Dans le titre du rapport, mets un tiret entre les deux mots et vérifie la barre de navigation.",
    "Nous serons 300 personnes au congrès, et la salle principale ouvrira à 9 heures et demie.",
    "Es un buen punto el que planteas, y nos vemos mañana a las 3 en punto.",
    "Después de la reunión tomamos algo en la barra del bar y el guion quedó perfecto.",
    "Mi abuelo contaba que vendían el trigo por arrobas, y que una arroba pesaba unos 11 kilos.",
    "Na końcu każdego zdania postaw kropkę, a pod ważnymi słowami narysuj kreskę.",
    "W zoo najbardziej podobała nam się małpa, która skakała po gałęziach.",
    "W tym miejscu wstaw myślnik, a nie przecinek.",
    "Dat is een goed punt dat je maakt, maar we moeten eerst afronden, punt uit.",
    "Zet er een streepje onder en teken een schuine streep door de oude datum.",
    "We zijn met 300 mensen op het congres, en de zaal gaat om half 10 open.",
    // colon words outside a link
    "Le match rapporte deux points à l'équipe.",
    "Ganamos dos puntos en el último partido.",
    "Na końcu wstaw dwukropek i wymień nazwiska.",
    "Zet een dubbele punt achter het woord.",
    // number dot words in prose
    "We staan 2 punt voor en hebben 3 punten.",
    "Mamy 2 kropka 5 procent wzrostu.",
    // at-words and hosts in prose
    "W zoo była małpa, a strona to zoo.pl.",
    "Ta małpa zoo.pl jest super.",
    "apenstaartjes zijn leuk",
    "Tomamos algo en la barra.",
    "Il tient la barre du bateau.",
    "Er staat een schuine streep op het bord.",
    // a Dutch digit word is read only after a Dutch dash word
    "Het model GPT tiret vier.",
    // the article or pronoun is never a glued code
    "Het is a-streepje 4.",
    // codes without a number
    "Het lied heet S streepje.",
    "Wstaw tu myślnik.",
    // a spoken host ending in an everyday word, with no www or protocol
    "Visita el sitio ejemplo punto ai barra docs.",
    // English prose on a take with no language verdict
    "We met at café dot com.",
    // English `slash` and a bare `barre` are not slash words on this route
    "See example.com slash help for more.",
    "exemple.fr barre aide",
    // a link that goes on past what reads: nothing converts
    "https dos puntos barra barra ejemplo punto es barra",
    "abre ejemplo punto es barra ayuda punto html",
    // a name longer than the pattern reads is refused whole, never converted from its tail
    "a punto b punto c punto d punto e punto f punto g punto h arroba gmail punto com",
    "jean guion paul guion pierre guion marie guion anne guion luc guion dupont arroba gmail punto com",
    // a missing name is never invented from the word before the at-word (local Codex diff review)
    "envía a arroba gmail punto com",
    "envía a arroba gmail.com",
    "stuur een bericht naar apenstaartje gmail punt com",
    "écris à arobase gmail point com",
    // German `at` beside a joined domain stays closed even with `punkt` in the name
    "john punkt smith at example.com",
    // an address with a path, or a host with a port, is left whole rather than half-converted
    "jan arroba ejemplo punto es barra ayuda",
    "escribe a maría arroba gmail punto com /ayuda",
    "ejemplo punto es dos puntos 8080 barra api",
    "https dos puntos barra barra ejemplo punto es dos puntos 8080",
    // a link that goes on in a way no pass reads stays whole, numbers inside it included
    "jan arroba ejemplo punto es barra 2 punto 5 punto 0",
    "http dos puntos barra barra ejemplo punto es barra api guion v2",
    "http dos puntos barra barra ejemplo punto es / ayuda",
    "Escribe un guion entre A y 2.",
    // a glued Dutch address whose name began with a spoken dot or dash stays whole
    "mail naar jan punt jansenapenstaartjebedrijf.nl",
    "mail naar jan streepje jansenapenstaartjebedrijf.nl",
    // a joined domain needs a real mailbox before it (diff review r6)
    "El símbolo arroba gmail.com",
    "Escribe arroba gmail.com",
    // a bare one-word name before a joined domain reads exactly like the line above, so it stays
    // too (diff review r8, declined: converting it would reopen "Escribe arroba gmail.com")
    "recepción arroba empresa.es",
    // a written ending the link pass does not read leaves the link whole (diff review r6)
    "https dos puntos barra barra ejemplo punto es.foo barra ayuda",
    "https dos puntos barra barra ejemplo punto es:8080",
    // a fully written address is the user's own text: nothing spoken, nothing changes (cloud review)
    "Visit WWW.Example.COM now",
    "Ga naar www.Voorbeeld.NL/help nu",
    // lost words are never inferred
    "Cuando arrancas el servidor, funciona en Localhost 2.3000 y puedes abrirlo.",
    "écris directement à gin.dupont.com et il te répondra.",
  ]

  @Test("what must not move", arguments: controls)
  func control(text: String) {
    #expect(neutral(text) == text)
  }

  @Test("one pass is enough: a second pass over the output changes nothing")
  func idempotent() {
    for row in Self.rows {
      let once = neutral(row.dictated)
      #expect(neutral(once) == once, "\(row.dictated)")
    }
  }

  /// The English route never reads the new words (#3226 keeps it byte-identical).
  nonisolated static let englishRouteUnchanged: [String] = [
    "S streepje 1", "GPT łącznik 4", "2 kropka 5 kropka 0", "192 punt 168 punt 1 punt 1",
    "ejemplo.es barra ayuda", "localhost dos puntos 3000", "recepción arroba empresa.es",
  ]

  @Test("the English route leaves the new words alone", arguments: englishRouteUnchanged)
  func englishRoute(text: String) {
    #expect(InverseTextNormalizer().normalize(text, spokenPunctuation: false) == text)
  }
}
