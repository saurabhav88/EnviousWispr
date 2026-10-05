import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

/// #2450: spoken punctuation in German, French, Spanish and Italian, behind a start word.
///
/// **Product Outcome.** When these fail a user either loses a command they asked for or, worse, loses a
/// word they said. The start word exists so the second cannot happen with a shipped default, and
/// `ordinaryUseIsNeverConverted` and the near-miss rows are what bind it.
///
/// Expected outputs are LITERAL throughout. `SpokenPunctuationRules` supplies some INPUTS (every form
/// of every table); it never supplies an expectation, because a test whose two sides both come from the
/// mechanism under test can only prove the mechanism agrees with itself.
///
/// NOT proven here, by design: behaviour through the real cleanup chain (snippet expansion before this
/// pass, polish after it), and what the shipping recogniser really writes around a command. Those belong
/// to the routing chunk and to Live UAT, and are recorded as pending.
@Suite(.tags(.productOutcome))
struct MultilingualSpokenPunctuationTests {

  private static let itn = InverseTextNormalizer()

  private static func apply(
    _ text: String, _ language: String = "de", start: String? = nil, sentinels: [String] = []
  ) -> SpokenPunctuationResult {
    itn.applyStartWordPunctuation(
      text, language: language,
      startWord: start ?? SpokenPunctuationRules.defaultStartWord(for: language) ?? "",
      protectedSentinels: sentinels)
  }

  private static func text(_ input: String, _ language: String = "de") -> String {
    apply(input, language).text
  }

  private static func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

  // MARK: - German commands

  @Test(
    "German commands convert after the start word",
    arguments: [
      (
        "wir treffen uns morgen Setze Punkt das Wetter ist gut",
        "wir treffen uns morgen. Das Wetter ist gut"
      ),
      (
        "wir treffen uns morgen Setze Komma das Wetter ist gut",
        "wir treffen uns morgen, das Wetter ist gut"
      ),
      ("ist das gut Setze Fragezeichen", "ist das gut?"),
      ("das ist gut Setze Ausrufezeichen", "das ist gut!"),
      ("hier kommt Setze Doppelpunkt der Rest", "hier kommt: der Rest"),
      ("erstens Setze Semikolon zweitens", "erstens; zweitens"),
      ("erstens Setze Strichpunkt zweitens", "erstens; zweitens"),
    ])
  func germanMarks(input: String, expected: String) {
    #expect(Self.text(input) == expected)
  }

  @Test(
    "German line and paragraph breaks, including the form the reporting user said",
    arguments: [
      ("alpha Setze neue Zeile beta", "alpha\nBeta"),
      ("alpha Setze neuer Absatz beta", "alpha\n\nBeta"),
      ("alpha Setze neuen Absatz beta", "alpha\n\nBeta"),
      ("alpha Setze Neuabsatz beta", "alpha\n\nBeta"),
    ])
  func germanBreaks(input: String, expected: String) {
    #expect(Self.text(input) == expected)
  }

  @Test("Case does not matter for the start word or the command")
  func caseVariants() {
    #expect(Self.text("alpha SETZE PUNKT beta") == "alpha. Beta")
    #expect(Self.text("alpha setze punkt beta") == "alpha. Beta")
    #expect(Self.text("alpha sEtZe KoMmA beta") == "alpha, beta")
  }

  // MARK: - French, Spanish, Italian

  @Test(
    "French commands, longest form first",
    arguments: [
      ("c'est fini Insère point", "c'est fini."),
      ("voulez-vous venir Insère point d'interrogation", "voulez-vous venir?"),
      ("quelle surprise Insère point d'exclamation", "quelle surprise!"),
      ("un deux Insère point-virgule trois", "un deux; trois"),
      ("un deux Insère virgule trois", "un deux, trois"),
      ("voici la liste Insère deux points les voici", "voici la liste: les voici"),
      ("alpha Insère nouvelle ligne beta", "alpha\nBeta"),
      ("alpha Insère à la ligne beta", "alpha\nBeta"),
      ("alpha Insère nouveau paragraphe beta", "alpha\n\nBeta"),
    ])
  func french(input: String, expected: String) {
    #expect(Self.text(input, "fr") == expected)
  }

  @Test("A typographic apostrophe from the engine still matches a French form")
  func frenchTypographicApostrophe() {
    #expect(
      Self.text("voulez-vous venir Insère point d\u{2019}interrogation", "fr")
        == "voulez-vous venir?")
  }

  @Test(
    "Spanish commands, longest form first",
    arguments: [
      ("hola Pon punto y coma adiós", "hola; adiós"),
      ("hola Pon punto adiós", "hola. Adiós"),
      ("hola Pon coma adiós", "hola, adiós"),
      ("mira esto Pon dos puntos aquí", "mira esto: aquí"),
      ("quién es Pon signo de interrogación", "quién es?"),
      ("qué bien Pon signo de exclamación", "qué bien!"),
      ("alpha Pon nueva línea beta", "alpha\nBeta"),
      ("alpha Pon nuevo párrafo beta", "alpha\n\nBeta"),
    ])
  func spanish(input: String, expected: String) {
    #expect(Self.text(input, "es") == expected)
  }

  @Test(
    "Italian commands, longest form first",
    arguments: [
      ("ciao Metti punto e virgola dopo", "ciao; dopo"),
      ("ciao Metti punto dopo", "ciao. Dopo"),
      ("ciao Metti virgola dopo", "ciao, dopo"),
      ("guarda Metti due punti ecco", "guarda: ecco"),
      ("come stai Metti punto interrogativo", "come stai?"),
      ("che bello Metti punto esclamativo", "che bello!"),
      ("alpha Metti nuova riga beta", "alpha\nBeta"),
      ("alpha Metti nuovo paragrafo beta", "alpha\n\nBeta"),
    ])
  func italian(input: String, expected: String) {
    #expect(Self.text(input, "it") == expected)
  }

  // MARK: - Ordinary use is never converted

  @Test(
    "Every command form of every language is untouched without its start word",
    arguments: SpokenPunctuationRules.supportedLanguages)
  func ordinaryUseIsNeverConverted(language: String) throws {
    let forms = try #require(SpokenPunctuationRules.spokenForms(for: language))
    #expect(forms.isEmpty == false)
    for form in forms {
      let sentence = "wir sagen \(form) und dann weiter"
      let result = Self.apply(sentence, language)
      #expect(result.text == sentence, "form: \(form)")
      #expect(result.rulesFired == 0, "form: \(form)")
    }
  }

  @Test(
    "German near misses and ordinary sentences stay byte-identical with the toggle's pass applied",
    arguments: [
      "Zeitpunkt",
      "der Standpunkt ist klar",
      "ein Schwerpunkt der Arbeit",
      "am Fußpunkt der Säule",
      "Punkt für Punkt gehen wir vor",
      "das ist der springende Punkt",
      "wir kommen auf den Punkt",
      "es kostet drei Komma fünf Prozent",
      "Besetze Punkt",
      "Setzen Punkt",
      "Setze dich bitte hin",
      "Setze Punktuation",
      "das ist ein Punkt Setze",
      "Setze",
      "",
    ])
  func germanNearMisses(input: String) {
    let result = Self.apply(input)
    #expect(result.text == input)
    #expect(result.rulesFired == 0)
  }

  @Test("A start word split from its command by a line break is not a command")
  func startWordAndCommandNeverSpanALineBreak() {
    #expect(Self.text("alpha Setze\nPunkt beta") == "alpha Setze\nPunkt beta")
    #expect(Self.text("alpha Setze\r\nPunkt beta") == "alpha Setze\r\nPunkt beta")
  }

  // MARK: - Whitespace

  @Test("Tabs and no-break spaces count as horizontal whitespace")
  func horizontalWhitespaceVariants() {
    #expect(Self.text("alpha\tSetze\u{00A0}Punkt beta") == "alpha. Beta")
    #expect(Self.text("alpha   Setze    Komma   beta") == "alpha,   beta")
  }

  @Test("The leading whitespace a match eats never includes a line break")
  func leadingWhitespaceStopsAtALineBreak() {
    #expect(Self.text("alpha\nSetze Punkt beta") == "alpha\n. Beta")
  }

  @Test("A line break a command produced survives the next command")
  func consecutiveBreakThenMark() {
    #expect(Self.text("alpha Setze neue Zeile Setze Punkt beta") == "alpha\n. Beta")
  }

  @Test("Indentation and list lines around a rewrite are untouched")
  func indentationAndListsAreKept() {
    #expect(Self.text("- item eins Setze Punkt\n- item zwei") == "- item eins.\n- item zwei")
    #expect(Self.text("    code Setze Komma weiter") == "    code, weiter")
    #expect(Self.text("alpha Setze neue Zeile   beta") == "alpha\nBeta")
  }

  // MARK: - Recogniser marks around a command

  @Test(
    "One recogniser period or comma directly after the command is absorbed",
    arguments: [
      ("Das ist gut Setze Punkt. Es geht weiter", "Das ist gut. Es geht weiter"),
      ("alpha Setze Komma, und beta", "alpha, und beta"),
      ("alpha Setze Neuer Absatz. Hallo", "alpha\n\nHallo"),
      ("alpha Setze Punkt.", "alpha."),
    ])
  func trailingRecogniserMark(input: String, expected: String) {
    #expect(Self.text(input) == expected)
  }

  /// Shapes the shipping recogniser (Parakeet v3) writes around a spoken command, taken from spoken
  /// samples (#2450 second-pass check): it punctuates the clause before the start word as a question
  /// or a sentence ("dir? Setze Fragezeichen"), ends with its own mark, and writes a French question
  /// mark after a space. The command REPLACES a mark the recogniser put on the word before it, and
  /// absorbs one it put after. Expected outputs are literal.
  @Test(
    "A mark the recogniser wrote around a command is replaced, never doubled",
    arguments: [
      ("de", "Wie geht es dir? Setze Fragezeichen.", "Wie geht es dir?"),
      ("de", "Das ist toll! Setze Ausrufezeichen.", "Das ist toll!"),
      ("de", "Wie geht es dir Setze Fragezeichen?", "Wie geht es dir?"),
      ("de", "Toll Setze Ausrufezeichen!", "Toll!"),
      ("de", "Hallo, Setze Komma wie geht es dir", "Hallo, wie geht es dir"),
      ("de", "Es kostet 5. Setze Punkt", "Es kostet 5."),
      ("fr", "Comment \u{00E7}a va ? Ins\u{00E8}re point d'interrogation", "Comment \u{00E7}a va?"),
      ("fr", "Comment \u{00E7}a va Ins\u{00E8}re point d'interrogation ?", "Comment \u{00E7}a va?"),
      ("fr", "Comment \u{00E7}a va\u{00A0}? Ins\u{00E8}re point d'interrogation", "Comment \u{00E7}a va?"),
      ("fr", "Comment \u{00E7}a va\u{202F}? Ins\u{00E8}re point d'interrogation", "Comment \u{00E7}a va?"),
      ("fr", "Comment \u{00E7}a va Ins\u{00E8}re point d'interrogation\u{00A0}?", "Comment \u{00E7}a va?"),
      ("fr", "C'est super Ins\u{00E8}re point d'exclamation\u{202F}!", "C'est super!"),
      ("fr", "C'est super Ins\u{00E8}re point d'exclamation !", "C'est super!"),
      ("es", "\u{00BF}C\u{00F3}mo est\u{00E1}s? Pon signo de interrogaci\u{00F3}n.", "\u{00BF}C\u{00F3}mo est\u{00E1}s?"),
      ("it", "Come stai? Metti punto interrogativo", "Come stai?"),
    ])
  func recogniserMarksAroundACommand(language: String, input: String, expected: String) {
    #expect(Self.text(input, language) == expected)
  }

  /// The pass cannot tell whether the recogniser or the user wrote a mark that DIFFERS from the one the
  /// command writes, so it keeps it: an abbreviation's dot, a list marker, a decimal, a different mark.
  @Test("A different mark before the start word is kept, never deleted")
  func differentMarksBeforeTheStartWordAreKept() {
    #expect(Self.text("z.B. Setze Komma weiter") == "z.B., weiter")
    #expect(Self.text("1. Setze Komma weiter") == "1., weiter")
    #expect(Self.text("3.14 Setze Punkt") == "3.14.")
    #expect(Self.text("Das ist toll. Setze Ausrufezeichen.") == "Das ist toll.!")
    #expect(Self.text("Wie geht es dir. Setze Fragezeichen") == "Wie geht es dir.?")
  }

  @Test("A line break keeps the sentence end it follows, and a lone ellipsis is not a recogniser mark")
  func breakAndEllipsisKeepTheirMarks() {
    #expect(Self.text("Erste Zeile. Setze neue Zeile zweite") == "Erste Zeile.\nZweite")
    #expect(Self.text("Moment\u{2026} Setze Punkt") == "Moment\u{2026}.")
    #expect(Self.text("Wirklich?! Setze Punkt") == "Wirklich?!.")
  }

  @Test("Two commands in a row still stack: the second never eats the first's mark")
  func adjacentCommandsStack() {
    #expect(Self.text("alpha Setze Komma Setze Punkt beta") == "alpha,. Beta")
    // Identical marks are the case the guard exists for: without it the second command would read the
    // first command's own mark as a recogniser duplicate and drop it.
    #expect(Self.text("alpha Setze Punkt Setze Punkt beta") == "alpha.. Beta")
    #expect(Self.text("alpha Setze Komma Setze Komma beta") == "alpha,, beta")
  }

  @Test("A dot glued to the next token is not absorbed")
  func gluedDotIsKept() {
    #expect(Self.text("alpha Setze Punkt.com") == "alpha..com")
  }

  // MARK: - Capitalisation

  @Test("Capitalisation happens only after a sentence-ending rewrite")
  func capitalisationScope() {
    #expect(Self.text("alpha Setze Komma beta gamma. delta") == "alpha, beta gamma. delta")
    #expect(Self.text("alpha Setze Punkt beta gamma. delta") == "alpha. Beta gamma. delta")
    #expect(Self.text("alpha Setze Punkt 42 beta") == "alpha. 42 beta")
    #expect(Self.text("alpha Setze Punkt «beta»") == "alpha. «Beta»")
    #expect(Self.text("alpha Setze Punkt\nbeta") == "alpha.\nBeta")
    #expect(Self.text("alpha Setze Punkt ßeta") == "alpha. SSeta")
    #expect(
      Self.apply("alpha Setze Punkt «zzsnip42»", sentinels: ["zzsnip42"]).text
        == "alpha. «zzsnip42»")
    #expect(Self.text("alpha Pon punto ¿cómo", "es") == "alpha. ¿Cómo")
  }

  @Test("An accented first letter is capitalised")
  func accentedCapital() {
    #expect(Self.text("alpha Pon punto élite", "es") == "alpha. Élite")
  }

  // MARK: - Consecutive commands and text edges

  @Test("Consecutive commands")
  func consecutiveCommands() {
    let result = Self.apply("alpha Setze Punkt Setze neuer Absatz beta")
    #expect(result.text == "alpha.\n\nBeta")
    #expect(result.rulesFired == 2)
  }

  @Test(
    "Commands at the very start and end of the text",
    arguments: [
      ("Setze Punkt", "."),
      ("Setze Komma", ","),
      ("Setze neue Zeile hallo", "\nHallo"),
      ("hallo Setze Punkt", "hallo."),
      ("hallo Setze Fragezeichen", "hallo?"),
    ])
  func edges(input: String, expected: String) {
    #expect(Self.text(input) == expected)
  }

  // MARK: - The start word is a setting

  @Test("A custom start word works and the default no longer does")
  func customStartWord() {
    #expect(Self.apply("alpha Diktiere Punkt beta", start: "Diktiere").text == "alpha. Beta")
    #expect(
      Self.apply("alpha Setze Punkt beta", start: "Diktiere").text == "alpha Setze Punkt beta")
  }

  @Test("A start word with an apostrophe or hyphen is matched literally")
  func customStartWordWithSeparators() {
    #expect(
      Self.apply("alpha mets-moi virgule beta", "fr", start: "mets-moi").text == "alpha, beta")
    #expect(Self.apply("alpha l'ordre point beta", "fr", start: "l'ordre").text == "alpha. Beta")
  }

  @Test("A start word full of regex metacharacters cannot widen the match")
  func startWordIsEscaped() {
    // Validation would refuse these; the pass must still treat them literally if one ever arrives.
    #expect(Self.apply("alpha Setzex Punkt beta", start: "Setz.").text == "alpha Setzex Punkt beta")
    #expect(
      Self.apply("alpha Setze Punkt beta", start: "(Setze|alpha)").text == "alpha Setze Punkt beta")
  }

  @Test("A decomposed start word is normalised and matches NFC text, and the result is exact")
  func decomposedStartWordMatchesComposedText() {
    let result = Self.apply("à demain Insère point", "fr", start: "Inse\u{0300}re")
    #expect(result.rulesFired == 1)
    #expect(Self.scalars(result.text) == Self.scalars("à demain."))
  }

  @Test("Decomposed commands match without normalising the surrounding text")
  func decomposedCommandsMatch() {
    let prefix = "cafe\u{0301}"
    let french = Self.apply("\(prefix) Inse\u{0300}re point beta", "fr")
    #expect(Self.scalars(french.text) == Self.scalars("\(prefix). Beta"))
    #expect(french.rulesFired == 1)

    let spanish = Self.apply("alpha Pon nuevo pa\u{0301}rrafo beta", "es")
    #expect(Self.scalars(spanish.text) == Self.scalars("alpha\n\nBeta"))
    #expect(spanish.rulesFired == 1)
  }

  @Test(
    "A language with no table, English included, is never given another table",
    arguments: ["en", "nl", "pl", "xx", ""])
  func unsupportedLanguage(language: String) {
    let input = "alpha Setze Punkt beta period comma"
    let result = Self.apply(input, language, start: "Setze")
    #expect(result.text == input)
    #expect(result.rulesFired == 0)
  }

  @Test(
    "A regional tag and any casing reach the same table",
    arguments: ["de", "de-DE", "de_DE", "DE", "De-at"])
  func regionalTags(language: String) {
    #expect(Self.apply("alpha Setze Punkt beta", language, start: "Setze").text == "alpha. Beta")
  }

  @Test("An empty or blank start word never matches anything")
  func emptyStartWord() {
    #expect(Self.apply("alpha Punkt beta", start: "").text == "alpha Punkt beta")
    #expect(Self.apply("alpha  Punkt beta", start: "  ").text == "alpha  Punkt beta")
  }

  // MARK: - Protected sentinels

  @Test("Capitalisation skips a protected sentinel and takes an ordinary word")
  func capitalisationSkipsASentinel() {
    let sentinel = "zzsnip42"
    #expect(
      Self.apply("alpha Setze Punkt zzsnip42 beta", sentinels: [sentinel]).text
        == "alpha. zzsnip42 beta")
    // Control: the same text without the sentinel being declared protected IS capitalised.
    #expect(Self.apply("alpha Setze Punkt zzsnip42 beta").text == "alpha. Zzsnip42 beta")
  }

  @Test("A sentinel before or after a command is carried through unchanged")
  func sentinelsSurviveAroundCommands() {
    let sentinel = "EWSNIP0123456789abcdef0123456789abcdef"
    let before = Self.apply("\(sentinel) Setze Punkt beta", sentinels: [sentinel])
    #expect(before.text == "\(sentinel). Beta")
    let after = Self.apply("alpha Setze Komma \(sentinel) beta", sentinels: [sentinel])
    #expect(after.text == "alpha, \(sentinel) beta")
  }

  // MARK: - Counts and idempotence

  @Test("The fired count is exact")
  func firedCounts() {
    #expect(Self.apply("alpha Setze Punkt beta Setze Komma gamma").rulesFired == 2)
    #expect(
      Self.apply("alpha Setze Punkt beta Setze Komma gamma Setze Fragezeichen").rulesFired == 3)
    #expect(Self.apply("alpha beta gamma").rulesFired == 0)
  }

  @Test("A second application changes nothing and fires nothing")
  func idempotence() {
    let inputs = [
      "alpha Setze Punkt beta Setze Komma gamma",
      "alpha Setze neuer Absatz beta Setze Fragezeichen",
      "alpha Setze Punkt. Es geht weiter",
    ]
    for input in inputs {
      let once = Self.apply(input)
      let twice = Self.apply(once.text)
      #expect(twice.text == once.text, "input: \(input)")
      #expect(twice.rulesFired == 0, "input: \(input)")
    }
  }

  // MARK: - The tables themselves

  @Test("Only de, fr, es and it have tables; nil, never empty, for the rest")
  func tableCoverage() {
    #expect(SpokenPunctuationRules.supportedLanguages == ["de", "fr", "es", "it"])
    for language in SpokenPunctuationRules.supportedLanguages {
      #expect(SpokenPunctuationRules.rules(for: language)?.isEmpty == false)
    }
    for language in ["en", "nl", "pl", "xx", ""] {
      #expect(SpokenPunctuationRules.rules(for: language) == nil, "language: \(language)")
      #expect(
        SpokenPunctuationRules.defaultStartWord(for: language) == nil, "language: \(language)")
    }
  }

  @Test("The German paragraph forms keep their display order, including the authored one")
  func germanParagraphFormsOrder() throws {
    let rules = try #require(SpokenPunctuationRules.rules(for: "de"))
    let paragraph = try #require(rules.first { $0.command == .paragraphBreak })
    #expect(paragraph.spokenForms == ["neuer Absatz", "neuen Absatz", "Neuabsatz"])
    #expect(paragraph.replacement == "\n\n")
  }

  @Test("Every language covers all eight commands exactly once")
  func everyLanguageCoversEveryCommand() throws {
    for language in SpokenPunctuationRules.supportedLanguages {
      let rules = try #require(SpokenPunctuationRules.rules(for: language))
      let commands = rules.map(\.command)
      #expect(Set(commands) == Set(SpokenPunctuationCommand.allCases), "language: \(language)")
      #expect(commands.count == SpokenPunctuationCommand.allCases.count, "language: \(language)")
    }
  }

  @Test("No spoken form is empty or repeated within a language")
  func formsAreWellFormed() throws {
    for language in SpokenPunctuationRules.supportedLanguages {
      let forms = try #require(SpokenPunctuationRules.spokenForms(for: language))
      #expect(forms.allSatisfy { $0.isEmpty == false }, "language: \(language)")
      let lowered = forms.map { $0.lowercased() }
      #expect(Set(lowered).count == lowered.count, "language: \(language)")
    }
  }
}
