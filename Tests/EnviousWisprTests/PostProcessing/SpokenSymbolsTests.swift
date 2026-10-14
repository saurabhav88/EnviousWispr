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

  private func startWord(_ text: String, _ language: String, _ word: String) -> String {
    normalizer.applyStartWordPunctuation(
      text, language: language, startWord: word, protectedSentinels: []
    ).text
  }

  // MARK: - English bare words

  @Test(
    "English bare words: each spacing class lands as typed",
    arguments: [
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
