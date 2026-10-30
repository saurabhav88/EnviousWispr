import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #3738: spoken symbols with Spoken punctuation on. When this fails, a user who says "left
/// parenthesis" gets the words (the ENVIOUSWISPR-77 report), a symbol lands with the wrong spacing, or a
/// sentence that only talks about a symbol is rewritten. Expected strings are written by hand from the
/// plan's spacing table (D1, D2), never derived from the implementation.
@Suite("Spoken symbols (#3738)", .tags(.productOutcome))
struct SpokenSymbolsTests {

  private let normalizer = InverseTextNormalizer()

  private func on(_ text: String) -> String { normalizer.normalize(text, spokenPunctuation: true) }

  private func startWord(
    _ text: String, _ language: String, _ word: String, periodWord: Bool = true
  ) -> String {
    normalizer.applyStartWordPunctuation(
      text, language: language, startWord: word, englishPeriodWord: periodWord,
      protectedSentinels: []
    ).text
  }

  // MARK: - English bare words

  @Test(
    "English bare words: each spacing class lands as typed",
    arguments: [
      // The Help Center article's own first example.
      ("Tuesday left parenthesis after lunch right parenthesis", "Tuesday (after lunch)"),
      (
        "The meeting is on Tuesday left parenthesis the 14th right parenthesis and it starts at noon.",
        "The meeting is on Tuesday (the 14th) and it starts at noon."
      ),
      (
        "Please review the doc open paren draft close paren before Friday.",
        "Please review the doc (draft) before Friday."
      ),
      ("Call the function open parenthesis close parenthesis now.", "Call the function () now."),
      ("The list is open square bracket apples close square bracket.", "The list is [apples]."),
      (
        "She said open quote I will be there close quote and left.",
        "She said \"I will be there\" and left."
      ),
      ("The key is open single quote yes close single quote.", "The key is 'yes'."),
      ("The file name is report underscore final.", "The file name is report_final."),
      ("We love rock ampersand roll.", "We love rock & roll."),
      (
        "The result was great em dash better than expected.",
        "The result was great\u{2014}better than expected."
      ),
      ("Wait for it ellipsis", "Wait for it\u{2026}"),
      ("Tag it hash sign urgent.", "Tag it #urgent."),
      ("Cat the file vertical bar grep error.", "Cat the file | grep error."),
      ("See the note asterisk.", "See the note*."),
    ])
  func englishSpacing(input: String, expected: String) {
    #expect(on(input) == expected)
  }

  @Test("English bare words: a hyphen the recogniser glued to the word before joins the two words")
  func gluedHyphen() {
    #expect(on("It is a well-hyphen known fact.") == "It is a well-known fact.")
    #expect(on("It is a well-hyphened known fact.") == "It is a well-known fact.")
  }

  @Test(
    "English bare words: a symbol named after a determiner stays words",
    arguments: [
      "Use an asterisk for the footnote.",
      "Add a hash sign before the tag.",
      "Pipe it with a vertical bar.",
      "The path starts with a tilde.",
      "Get a quote from the vendor.",
    ])
  func determinerKeepsWords(input: String) {
    #expect(on(input) == input)
  }

  @Test("English bare words: a symbol word with no determiner converts (accepted limit, D4)")
  func determinerFreeMentionConverts() {
    #expect(on("Hyphen separates words.") == "-separates words.")
  }

  @Test("English bare words: nothing converts while Spoken punctuation is off")
  func offSwitch() {
    let input = "Tuesday left parenthesis the 14th right parenthesis"
    #expect(normalizer.normalize(input, spokenPunctuation: false) == input)
  }

  @Test("English bare words: a sentence end after a closing symbol stays")
  func markAfterSymbolStays() {
    #expect(on("Say hi close paren.") == "Say hi).")
    #expect(on("Done period close quote") == "Done.\"")
  }

  @Test("English bare words: a spoken slash inside brackets still reads as a command")
  func slashInsideBrackets() {
    #expect(on("Run open paren slash clear close paren now.") == "Run (/clear) now.")
  }

  /// Build review r3: a symbol rendered beside a spoken slash or backslash must not hide the word
  /// from the joiner pass, on either side, and no gap character may reach the output.
  @Test("English bare words: symbols beside a spoken backslash or slash keep the joiner working")
  func joinerBesideSymbols() {
    #expect(on("Run open paren backslash close paren now") == "Run (\\) now")
    #expect(
      on("Run open angle bracket backslash path close angle bracket now") == "Run <\\path> now")
    #expect(on("Type underscore backslash now") == "Type_\\now")
    #expect(on("Type backslash underscore name now") == "Type\\_name now")
    #expect(on("See open paren and slash close paren now") == "See (and slash) now")
    #expect(
      on("Run open angle bracket slash path close angle bracket").contains("\u{200A}") == false)
    // Second-pass review: a legacy command right after an opening symbol, and a symbol name that is
    // part of a hyphenated or accented word.
    #expect(on("Run open paren comma close paren") == "Run (,)")
    #expect(on("Use tilde-based notation") == "Use tilde-based notation")
    #expect(on("Use underscore\u{0301} notation") == "Use underscore\u{0301} notation")
    // An engine comma glued to the backslash was the only separator (build review r4).
    #expect(
      on("Run open angle bracket,backslash path close angle bracket now") == "Run <\\path> now")
    // A spaced symbol before a spoken backslash keeps its own space and glues as before.
    #expect(on("Set x equals sign backslash path now") == "Set x =\\path now")
    // Start-word route: the slash is read by the bare-word pass before the start-word symbols render.
    let bare = normalizer.normalize(
      "Run Insert open paren slash clear Insert close paren now", spokenPunctuation: false)
    #expect(startWord(bare, "en", "Insert") == "Run (/clear) now")
    // A transcript's own hair space is never removed, and the pass still runs.
    #expect(on("Run open paren x close paren\u{200A}now") == "Run (x)\u{200A}now")
    // The gap is only kept for the joiner pass. When the joiner leaves the slash as a plain word
    // (a capitalised "Slash" mid-sentence), the gap must still be removed from the output (#3753).
    #expect(on("Type underscore Slash now").contains("\u{200A}") == false)
    #expect(on("Type Slash close paren now").contains("\u{200A}") == false)
  }

  /// Every English symbol form on BOTH English routes, with the expected spacing written from the plan's
  /// table (D2), not from the renderer: opens keeps the space before and joins the next word, closes
  /// joins the word before, joins removes both spaces, spaced puts one space on each side.
  /// The symbol and spacing class of every English symbol command, written by hand from the plan's
  /// table (D1, D2), never read from the rule or the command under test.
  private static let expectedSymbol: [SpokenPunctuationCommand: (symbol: String, spacing: String)] =
    [
      .openParenthesis: ("(", "opens"), .closeParenthesis: (")", "closes"),
      .openSquareBracket: ("[", "opens"), .closeSquareBracket: ("]", "closes"),
      .openBrace: ("{", "opens"), .closeBrace: ("}", "closes"),
      .openAngleBracket: ("<", "opens"), .closeAngleBracket: (">", "closes"),
      .openQuote: ("\"", "opens"), .closeQuote: ("\"", "closes"),
      .openSingleQuote: ("'", "opens"), .closeSingleQuote: ("'", "closes"),
      .hyphen: ("-", "joins"), .underscore: ("_", "joins"), .apostrophe: ("'", "joins"),
      .emDash: ("\u{2014}", "joins"), .enDash: ("\u{2013}", "spaced"),
      .ellipsis: ("\u{2026}", "closes"),
      .ampersand: ("&", "spaced"), .plusSign: ("+", "spaced"), .equalsSign: ("=", "spaced"),
      .verticalBar: ("|", "spaced"), .asterisk: ("*", "closes"), .hashSign: ("#", "opens"),
      .tilde: ("~", "opens"),
    ]

  @Test("Every English symbol form converts with its class's spacing on both English routes")
  func everyEnglishFormBothRoutes() {
    let rules = SpokenPunctuationRules.englishSymbolRules
    #expect(
      Set(rules.map(\.command)) == Set(Self.expectedSymbol.keys), "the English symbol set drifted")
    for rule in rules {
      guard let want = Self.expectedSymbol[rule.command] else {
        Issue.record("\(rule.command) has no hand-written expectation")
        continue
      }
      let expected: String
      switch want.spacing {
      case "opens": expected = "Alpha " + want.symbol + "beta"
      case "closes": expected = "Alpha" + want.symbol + " beta"
      case "joins": expected = "Alpha" + want.symbol + "beta"
      default: expected = "Alpha " + want.symbol + " beta"
      }
      for form in rule.spokenForms {
        #expect(on("Alpha \(form) beta") == expected, "bare: \(form)")
        #expect(
          startWord("Alpha Insert \(form) beta", "en", "Insert") == expected, "start word: \(form)")
      }
    }
  }

  @Test("Every determiner keeps a symbol name as words")
  func everyDeterminer() {
    for word in [
      "a", "an", "the", "this", "that", "each", "every", "my", "your", "our", "their", "his", "her",
      "its",
    ] {
      let input = "Use \(word) asterisk now"
      #expect(on(input) == input, "\(word)")
    }
  }

  @Test("Spaced symbols stay tight against a line break, and nested and adjacent brackets join")
  func boundaries() {
    #expect(startWord("Alpha Insert ampersand\nbeta", "en", "Insert") == "Alpha &\nbeta")
    // Cloud review PR #3755: no space before the engine's punctuation or a closer, none after an
    // opener; the start-word route has no later tightening pass.
    #expect(startWord("Set x Insert equals sign, then y", "en", "Insert") == "Set x =, then y")
    #expect(startWord("Insert ampersand. Next", "en", "Insert") == "&. Next")
    #expect(
      startWord("Insert open paren Insert plus sign Insert close paren", "en", "Insert") == "(+)")
    #expect(on("Set x equals sign, then y") == "Set x =, then y")
    // A straight quote opens and closes, so a spaced symbol after a closing one keeps its space.
    #expect(
      on("Add open quote x close quote plus sign open quote y close quote") == "Add \"x\" + \"y\"")
    #expect(
      startWord(
        "Add Insert open quote a Insert close quote Insert plus sign Insert open quote b Insert close quote",
        "en", "Insert") == "Add \"a\" + \"b\"")
    #expect(startWord("Insert ampersand beta", "en", "Insert") == "& beta")
    #expect(startWord("Alpha Insert ampersand", "en", "Insert") == "Alpha &")
    #expect(on("Call open paren open paren x close paren close paren") == "Call ((x))")
    #expect(on("Say open paren open quote hi close quote close paren") == "Say (\"hi\")")
    #expect(on("Only open paren here") == "Only (here")
  }

  /// Shapes from real dictation (the founder's History, read locally): the engine puts a comma at the
  /// pause around a spoken symbol.
  @Test(
    "An engine comma inside a symbol pair goes; one after the closing symbol stays",
    arguments: [
      (
        "Say open parenthesis, urgent, close parenthesis, send it today.",
        "Say (urgent), send it today."
      ),
      (
        "It should say open paren user ID, colon string, close paren returns bool.",
        "It should say (user ID: string) returns bool."
      ),
      ("Set API, underscore, key first.", "Set API_key first."),
      ("Keep it open paren see above. close paren", "Keep it (see above.)"),
    ])
  func engineCommaInsidePair(input: String, expected: String) {
    #expect(on(input) == expected)
  }

  @Test(
    "An explicitly spoken comma inside a pair survives on both routes; comma runs are left alone")
  func explicitCommaInsidePair() {
    #expect(on("Call open paren x comma close paren") == "Call (x,)")
    #expect(
      startWord("Call Insert open paren x Insert comma Insert close paren", "en", "Insert")
        == "Call (x,)")
    #expect(on("Odd open paren,, x,, close paren") == "Odd (,, x,,)")
  }

  @Test("A legacy command right after a joining symbol is still converted")
  func legacyAfterJoiningSymbol() {
    #expect(startWord("Hello Insert underscore Insert comma", "en", "Insert") == "Hello_,")
  }

  @Test("A capital pending after a full stop lands after every opening symbol")
  func capitalAfterEveryOpener() {
    #expect(
      startWord("Done Insert period Insert open angle bracket beta", "en", "Insert")
        == "Done. <Beta")
    #expect(startWord("Done Insert period Insert hash sign beta", "en", "Insert") == "Done. #Beta")
  }

  @Test("A start word that is a symbol's first word still gates the symbol")
  func symbolFirstWordStartWord() {
    #expect(startWord("Call Open open paren x", "en", "Open") == "Call (x")
  }

  @Test("A closing symbol after a spoken period means the period is not the last character")
  func periodThenSymbolProvenance() {
    let result = normalizer.normalizeReportingFinalFullStop(
      "see you period close paren",
      spokenPunctuation: InverseTextNormalizer.bareEnglishSettings(enabled: true))
    #expect(result.spokenFinalFullStop == false)
  }

  // MARK: - Start word

  @Test("German start word: brackets, quotes, hyphen and ellipsis")
  func german() {
    #expect(
      startWord(
        "Wir treffen uns Diktiere linke Klammer am Dienstag Diktiere rechte Klammer", "de",
        "Diktiere") == "Wir treffen uns (am Dienstag)")
    #expect(
      startWord(
        "Er sagte Diktiere Anführungszeichen unten hallo Diktiere Anführungszeichen oben", "de",
        "Diktiere") == "Er sagte \u{201E}hallo\u{201C}")
    #expect(startWord("E Diktiere Bindestrich Mail", "de", "Diktiere") == "E-Mail")
    #expect(
      startWord("Und dann Diktiere Auslassungspunkte", "de", "Diktiere") == "Und dann\u{2026}")
  }

  @Test("German start word: a word without the start word stays a word")
  func germanBareWordStays() {
    let input = "Die linke Klammer ist kaputt"
    #expect(startWord(input, "de", "Diktiere") == input)
  }

  @Test("Start word: a capital pending after a sentence end lands inside an opening bracket")
  func capitalInsideBracket() {
    #expect(
      startWord(
        "Gut Diktiere Punkt Diktiere linke Klammer beta Diktiere rechte Klammer", "de", "Diktiere")
        == "Gut. (Beta)")
  }

  /// Cloud review PR #3755 and its two local rounds: every pairing of an opener, a quote or a
  /// guillemet with the command after it, on both routes. Expected text written by hand.
  @Test("Openers, quotes and guillemets keep typed spacing next to the following command")
  func openerAndQuoteBoundaries() {
    let en = { (text: String) in self.startWord(text, "en", "Insert") }
    // An opener, then a spaced symbol: no space inside.
    #expect(en("Set Insert open quote Insert plus sign Insert close quote") == "Set \"+\"")
    #expect(on("Set open quote plus sign close quote") == "Set \"+\"")
    #expect(on("Set open paren plus sign close paren") == "Set (+)")
    // An opener, then a closer, a joiner or a mark.
    #expect(en("Set Insert open quote Insert close quote") == "Set \"\"")
    #expect(en("Set Insert open quote Insert underscore x") == "Set \"_x")
    #expect(en("Set Insert open quote Insert comma") == "Set \",")
    // A closing quote, then a spaced symbol or a mark.
    #expect(en("Set Insert open quote x Insert close quote Insert ampersand y") == "Set \"x\" & y")
    #expect(en("Set Insert open quote x Insert close quote Insert comma") == "Set \"x\",")
    // A spaced symbol, then a quote.
    #expect(en("Set x Insert plus sign Insert open quote y Insert close quote") == "Set x + \"y\"")
    // French guillemets keep their no-break spaces next to the command after them.
    let fr = { (text: String) in self.startWord(text, "fr", "Place") }
    #expect(fr("Il dit Place guillemet ouvrant Place points de suspension") == "Il dit \u{00AB}\u{00A0}\u{2026}")
    #expect(fr("Il dit Place guillemet ouvrant Place virgule") == "Il dit \u{00AB}\u{00A0},")
    #expect(
      fr("Il dit Place guillemet ouvrant Place nouvelle ligne oui")
        == "Il dit \u{00AB}\nOui")
    #expect(
      fr("Il dit Place guillemet ouvrant oui Place guillemet fermant Place point")
        == "Il dit \u{00AB}\u{00A0}oui\u{00A0}\u{00BB}.")
  }

  @Test("French start word: guillemets carry the no-break space inside")
  func frenchGuillemets() {
    #expect(
      startWord("Il a dit Place guillemet ouvrant bonjour Place guillemet fermant", "fr", "Place")
        == "Il a dit \u{00AB}\u{00A0}bonjour\u{00A0}\u{00BB}")
  }

  @Test(
    "English start word: symbols need the start word, and the English table matches the bare route")
  func englishStartWord() {
    #expect(
      startWord("Call it Insert open paren Insert close paren", "en", "Insert") == "Call it ()")
    #expect(startWord("Rock Insert ampersand roll", "en", "Insert") == "Rock & roll")
    #expect(startWord("Rock ampersand roll", "en", "Insert") == "Rock ampersand roll")
  }

  @Test("Start word: a closing symbol after a spoken full stop leaves the engine's dot alone")
  func germanMarkAfterSymbol() {
    #expect(
      startWord("Fertig Diktiere Punkt Diktiere rechte Klammer.", "de", "Diktiere") == "Fertig.).")
  }

  // MARK: - Start-word collisions (D5c)

  @Test("A start word that is a symbol's first word stays valid")
  func symbolFirstWordIsNotACollision() throws {
    let forms = try #require(SpokenPunctuationRules.startWordForms(for: "en"))
    for word in ["Open", "Left", "Close", "Right"] {
      #expect(
        SpokenPunctuationStartWord.validate(word, language: "en", spokenForms: forms)
          == .accepted(word), "\(word)")
    }
  }

  @Test("Every symbol command has a role and a spacing, and every legacy one has neither spacing")
  func rolesAndSpacing() {
    for command in SpokenPunctuationCommand.allCases {
      switch command.role {
      case .symbol: #expect(command.spacing != nil, "\(command)")
      case .mark, .lineBreak: #expect(command.spacing == nil, "\(command)")
      }
    }
  }
}

// MARK: - #4216 symbol spacing with the English period switch

extension SpokenSymbolsTests {

  private func bare(_ text: String, periodWord: Bool) -> String {
    normalizer.normalizeReportingFinalFullStop(
      text,
      spokenPunctuation: SpokenPunctuationSettings(
        enabled: true, startWordOverrides: [:], englishPeriodWord: periodWord)
    ).text
  }

  private func viaStartWord(_ text: String, periodWord: Bool) -> SpokenPunctuationResult {
    normalizer.applyStartWordPunctuation(
      text, language: "en", startWord: "Open", englishPeriodWord: periodWord,
      protectedSentinels: [])
  }

  @Test(
    "Bare route: literal spacing and case beside symbols in both period switch positions",
    arguments: [
      // (input, period switch, expected)
      ("open paren period close paren", false, "(period)"),
      ("open paren period close paren", true, "(.)"),
      ("open paren full stop close paren", false, "(.)"),
      ("alpha underscore period beta", false, "alpha_period beta"),
      ("alpha underscore period beta", true, "alpha_. Beta"),
      ("alpha slash period beta", false, "alpha/period beta"),
      ("period slash beta", false, "period/beta"),
      ("alpha backslash period beta", false, "alpha\\period beta"),
      ("alpha period beta", false, "alpha period beta"),
      ("alpha period beta", true, "alpha. Beta"),
      ("alpha full stop beta", false, "alpha. Beta"),
    ])
  func bareLiterals(input: String, periodWord: Bool, expected: String) {
    #expect(bare(input, periodWord: periodWord) == expected, "\(input) periodWord=\(periodWord)")
  }

  @Test(
    "Start word route: literal spacing and case in both period switch positions",
    arguments: [
      ("Call Open open paren Open period Open close paren", false, "Call (Open period)"),
      ("Call Open open paren Open period Open close paren", true, "Call (.)"),
      ("Call Open open paren Open full stop Open close paren", false, "Call (.)"),
      ("alpha Open period beta", false, "alpha Open period beta"),
      ("alpha Open period beta", true, "alpha. Beta"),
      ("alpha Open full stop beta", false, "alpha. Beta"),
      ("alpha Open underscore Open period beta", false, "alpha_Open period beta"),
      ("alpha Open underscore Open period beta", true, "alpha_. Beta"),
    ])
  func startWordLiterals(input: String, periodWord: Bool, expected: String) {
    #expect(viaStartWord(input, periodWord: periodWord).text == expected, "\(input) periodWord=\(periodWord)")
  }

  @Test("Start word route: the final full stop report follows the period switch")
  func startWordFinalFullStopReport() {
    #expect(viaStartWord("see you Open period", periodWord: false).spokenFinalFullStop == false)
    #expect(viaStartWord("see you Open full stop", periodWord: false).spokenFinalFullStop)
    #expect(viaStartWord("see you Open period", periodWord: true).spokenFinalFullStop)
  }
}
