import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #2450: spoken punctuation in German, French, Spanish and Italian, behind a start word.
///
/// **Product Outcome.** When these fail a German user either loses a command they asked
/// for, or — far worse — loses a word they said. The second is what the start word
/// exists to make impossible, and `ordinaryUseIsNeverConverted` is the case that binds
/// it.
///
/// Expected outputs are LITERAL throughout. `SpokenPunctuationRules` supplies the inputs
/// in a few places; it never supplies the expectation, because a test whose both sides
/// come from the mechanism under test can only prove the mechanism agrees with itself.
@Suite(.tags(.productOutcome))
struct MultilingualSpokenPunctuationTests {

  private static let itn = InverseTextNormalizer()

  private static func apply(_ text: String, _ language: String) -> String {
    itn.applySpokenPunctuation(
      text, language: language,
      startWord: SpokenPunctuationRules.startWord(for: language)
    ).text
  }

  // MARK: - The commands work

  @Test(
    "German commands convert after the start word",
    arguments: [
      ("wir treffen uns morgen setze Punkt das Wetter ist gut", "wir treffen uns morgen."),
      ("wir treffen uns morgen setze Komma das Wetter ist gut", "wir treffen uns morgen,"),
      ("das ist gut setze Fragezeichen", "das ist gut?"),
      ("das ist gut setze Ausrufezeichen", "das ist gut!"),
      ("hier kommt setze Doppelpunkt der Rest", "hier kommt:"),
      ("erstens setze Semikolon zweitens", "erstens;"),
      ("erstens setze Strichpunkt zweitens", "erstens;"),
    ])
  func germanCommands(input: String, expectedPrefix: String) {
    let out = Self.apply(input, "de")
    #expect(out.hasPrefix(expectedPrefix), "got \(out.debugDescription)")
  }

  @Test("German paragraph and line breaks, including the colloquial form")
  func germanBreaks() {
    #expect(Self.apply("alpha setze neue Zeile beta", "de").contains("\n"))
    #expect(Self.apply("alpha setze neuer Absatz beta", "de").contains("\n\n"))
    // `Neuabsatz` is what the reporting user actually said. A textbook list omits it.
    #expect(Self.apply("alpha setze Neuabsatz beta", "de").contains("\n\n"))
  }

  @Test(
    "French, Spanish and Italian commands convert after their start words",
    arguments: [
      ("on se voit demain insère point le temps sera beau", "fr", "on se voit demain."),
      ("on se voit demain insère virgule le temps", "fr", "on se voit demain,"),
      ("nos vemos mañana pon punto el tiempo", "es", "nos vemos mañana."),
      ("nos vemos mañana pon coma el tiempo", "es", "nos vemos mañana,"),
      ("ci vediamo domani metti punto il tempo", "it", "ci vediamo domani."),
      ("ci vediamo domani metti virgola il tempo", "it", "ci vediamo domani,"),
    ])
  func romanceCommands(input: String, language: String, expectedPrefix: String) {
    let out = Self.apply(input, language)
    #expect(out.hasPrefix(expectedPrefix), "got \(out.debugDescription)")
  }

  // MARK: - The start word is what makes this safe

  /// **The case this whole design exists for.** Every one of these is ordinary speech
  /// containing a punctuation NOUN. Without a start word a table like this converts them
  /// and silently deletes a word the user said; #1367 measured that failure at 43.9% on
  /// real text. With a start word it cannot happen, and this test is what says so.
  @Test(
    "Ordinary use of a punctuation word is never converted",
    arguments: [
      ("Der wichtigste Punkt Deutschlands ist die Wirtschaft", "de"),
      ("Das ist der springende Punkt und wir gehen Punkt für Punkt vor", "de"),
      ("Bei dieser Zahl steht das Komma an der falschen Stelle", "de"),
      ("Wir haben diesen Punkt gestern schon besprochen", "de"),
      ("Meine Tochter lernt das Komma in der Schule", "de"),
      ("Nous sommes sur le point de partir maintenant", "fr"),
      ("La virgule est mal placée dans ce nombre", "fr"),
      ("El punto más importante es la economía del país", "es"),
      ("La coma está mal puesta en esa cifra", "es"),
      ("Il punto più importante resta da discutere", "it"),
      ("La virgola è nel posto sbagliato in quel numero", "it"),
    ])
  func ordinaryUseIsNeverConverted(input: String, language: String) {
    let out = Self.apply(input, language)
    #expect(out == input, "ordinary speech was rewritten: \(out.debugDescription)")
  }

  /// Apple gets several of the rows above WRONG — measured 2026-08-26, e.g.
  /// `Bei dieser Zahl steht das Komma an der falschen Stelle` comes back as
  /// `... steht das, an der falschen Stelle` from `DictationTranscriber`. Ours cannot,
  /// and that is a property of the grammar rather than of a better word list.
  @Test("German compounds never expose an internal command word")
  func compoundsAreSafe() {
    // `reSub` compiles WITHOUT `.useUnicodeWordBoundaries`, so a bare `\b` treats `ß` as
    // a non-word character and `\bpunkt\b` would match inside `Fußpunkt`. The rules use
    // explicit Unicode lookarounds for exactly this. `Fußpunkt` is the case that fails
    // if anyone "simplifies" them back to `\b`.
    for word in ["Zeitpunkt", "Standpunkt", "Schwerpunkt", "Blickpunkt", "Höhepunkt", "Fußpunkt"] {
      let input = "Der \(word) ist erreicht"
      #expect(Self.apply(input, "de") == input, "compound was split: \(word)")
    }
    // And the same word preceded by the start word IS a command, so the test above
    // cannot pass by the matcher being broken outright.
    #expect(Self.apply("Der Zeitpunkt setze Punkt", "de").hasSuffix("."))
  }

  // MARK: - Ordering

  /// Non-English commands NEST where English's do not. Shortest-first turns
  /// `insère point d'interrogation` into `. d'interrogation` and destroys the command.
  @Test(
    "The longest matching command wins",
    arguments: [
      ("alpha insère point d'interrogation", "fr", "?"),
      ("alpha insère point d'exclamation", "fr", "!"),
      ("alpha insère point-virgule", "fr", ";"),
      ("alpha pon punto y coma", "es", ";"),
      ("alpha pon dos puntos", "es", ":"),
      ("alpha pon signo de interrogación", "es", "?"),
      ("alpha metti punto e virgola", "it", ";"),
      ("alpha metti due punti", "it", ":"),
      ("alpha metti punto interrogativo", "it", "?"),
    ])
  func longestFormWins(input: String, language: String, expectedMark: String) {
    let out = Self.apply(input, language)
    #expect(out == "alpha\(expectedMark)", "got \(out.debugDescription)")
  }

  // MARK: - Language routing

  @Test("An unsupported language has no table and rewrites nothing")
  func unsupportedLanguage() {
    #expect(SpokenPunctuationRules.table(for: "nl") == nil)
    #expect(SpokenPunctuationRules.table(for: "pl") == nil)
    #expect(SpokenPunctuationRules.table(for: "ja") == nil)
    let dutch = "Dit is het belangrijkste punt van de dag"
    #expect(Self.apply(dutch, "nl") == dutch)
  }

  @Test("Locale-shaped codes still find their table")
  func localeShapedCodes() {
    #expect(SpokenPunctuationRules.table(for: "de-DE") != nil)
    #expect(SpokenPunctuationRules.table(for: "de_DE") != nil)
    #expect(SpokenPunctuationRules.table(for: "DE") != nil)
    #expect(SpokenPunctuationRules.startWord(for: "de-DE") == "setze")
  }

  @Test("English is the only bare-command language")
  func englishIsBare() {
    #expect(SpokenPunctuationRules.startWord(for: "en") == nil)
    for language in ["de", "fr", "es", "it"] {
      #expect(
        SpokenPunctuationRules.startWord(for: language) != nil,
        "\(language) must require a start word")
    }
  }

  /// The English table reached through the new owner must still be the shipped one.
  /// `SpokenPunctuationToggleTests` proves the BEHAVIOUR is unchanged across a 2,064-row
  /// corpus; this pins the patterns themselves, including the `\b` versus `\s+`
  /// asymmetry that a tidy-up would erase.
  @Test("The English patterns are carried verbatim")
  func englishPatternsVerbatim() {
    let patterns = (SpokenPunctuationRules.table(for: "en") ?? []).map(\.pattern)
    #expect(
      patterns == [
        #"\bnew paragraph\b"#, #"\bnew line\b"#,
        #"\s+comma\b"#, #"\s+period\b"#, #"\s+full stop\b"#,
        #"\s+question mark\b"#, #"\s+exclamation (mark|point)\b"#,
        #"\s+colon\b"#, #"\s+semicolon\b"#,
      ])
  }

  // MARK: - Help-panel data

  @Test("Every supported language renders a non-empty, complete phrase list")
  func phrasesCoverEveryRule() {
    for language in SpokenPunctuationRules.supportedLanguages {
      let rules = SpokenPunctuationRules.table(for: language) ?? []
      let phrases = SpokenPunctuationRules.phrases(for: language)
      #expect(rules.isEmpty == false, "\(language) has no rules")
      #expect(
        phrases.count == rules.reduce(0) { $0 + $1.spokenForms.count },
        "\(language): every spoken form must appear in the panel")
      #expect(
        Set(phrases.map(\.spoken)).count == phrases.count,
        "\(language): duplicate phrase rows would render twice")
    }
  }

  @Test("An unsupported language renders no phrases rather than English ones")
  func phrasesForUnsupported() {
    #expect(SpokenPunctuationRules.phrases(for: "nl").isEmpty)
  }
}
