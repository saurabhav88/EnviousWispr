import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2450: the in-app word table is gone. The Help Center article owns the list, so the freeze that
/// pinned the table's phrases against the rules (`phrasesAreFrozen`, `spokenPhrasesAreUnique`) has
/// nothing left to protect: with no phrase inventory in the app there is no second copy to drift.
/// What stays is the wording a user can be misled by (the footnote, the English line, the polish
/// line), the link, one refusal message per validator outcome, and the brand rule on dashes.
struct SpokenPunctuationCopyTests {

  /// #3038: the footnote is the only place the app describes the always-on slash, so its exact
  /// wording is pinned: the three shapes (a command, a command in a sentence, a pair), the verb
  /// that stays words, and the non-categorical "can still" for the known miss.
  @Test("The footnote keeps the English warning and describes the always-on slash")
  func footnoteIsFrozen() {
    #expect(
      SpokenPunctuationCopy.helpFootnote
        == "In English with no start word, these words become marks even when you meant the word itself, like \"the grace "
        + "period expires\". Slash works with this setting off: \"slash clear\" becomes /clear, "
        + "\"command is slash wfp\" becomes command is /wfp, \"pros slash cons\" becomes "
        + "pros/cons, and \"slash the budget\" stays words. Some verb uses, like \"slash prices\", "
        + "can still become a symbol.")
    #expect(SpokenPunctuationCopy.helpFootnote.contains("always") == false)
  }

  @Test("The help says English is unchanged and that the setting is meant for polish off")
  func helpLines() {
    #expect(
      SpokenPunctuationCopy.helpEnglish
        == "English works as it does today: say the word on its own. You can also give English a start word.")
    #expect(SpokenPunctuationCopy.helpPolish.contains("AI polish off"))
    #expect(SpokenPunctuationCopy.helpPolish.contains("protect") == false)
  }

  @Test("The row keeps one short line; the help says how to pick a word, that blank means none, and that the picker is not the dictation language")
  func rowLines() {
    #expect(SpokenPunctuationCopy.startWordShort == "The word you say before a mark.")
    #expect(
      SpokenPunctuationCopy.startWordHelp.contains(
        "Pick a word you would not say in a normal sentence"))
    #expect(SpokenPunctuationCopy.startWordHelp.contains("Leave the field blank"))
    #expect(SpokenPunctuationCopy.languagePickerLabel == "Start word for")
    #expect(
      SpokenPunctuationCopy.pickerIsNotDictationLanguage.contains(
        "does not change your dictation language")
    )
  }

  @Test("The learn-more link points at the article that owns the word list")
  func learnMoreLink() throws {
    let url = try #require(SpokenPunctuationCopy.learnMoreURL)
    #expect(url.absoluteString == "https://enviouswispr.com/help/spoken-punctuation-and-emoji/")
    #expect(SpokenPunctuationCopy.learnMoreLabel == "Learn more")
  }

  /// `Refusal` is not `CaseIterable`; the copy's own `switch` is exhaustive, so a new case fails to
  /// compile there, and this list is what proves every current case reads as a sentence.
  @Test("Every refusal has its own plain message")
  func everyRefusalHasAMessage() {
    let all: [SpokenPunctuationStartWord.Refusal] = [
      .empty, .notOneToken, .invalidCharacters, .tooShort, .tooLong, .collidesWithCommand,
      .unsupportedLanguage,
    ]
    let messages = all.map(SpokenPunctuationCopy.rejection)
    #expect(Set(messages).count == all.count, "two refusals share one message")
    for message in messages {
      #expect(message.isEmpty == false)
    }
  }

  /// Brand rule: no em-dashes or en-dashes in user-facing copy.
  @Test("User-facing strings carry no em-dash or en-dash")
  func noDashes() {
    let refusals: [SpokenPunctuationStartWord.Refusal] = [
      .empty, .notOneToken, .invalidCharacters, .tooShort, .tooLong, .collidesWithCommand,
      .unsupportedLanguage,
    ]
    let strings =
      [
        SpokenPunctuationCopy.toggleLabel,
        SpokenPunctuationCopy.toggleDescription,
        SpokenPunctuationCopy.helpStartWord,
        SpokenPunctuationCopy.helpEnglish,
        SpokenPunctuationCopy.helpPolish,
        SpokenPunctuationCopy.helpFootnote,
        SpokenPunctuationCopy.learnMoreLabel,
        SpokenPunctuationCopy.learnMoreAccessibilityLabel,
        SpokenPunctuationCopy.startWordTitle,
        SpokenPunctuationCopy.startWordShort,
        SpokenPunctuationCopy.startWordHelp,
        SpokenPunctuationCopy.languagePickerLabel,
        SpokenPunctuationCopy.pickerIsNotDictationLanguage,
        SpokenPunctuationCopy.resetLabel,
        SpokenPunctuationCopy.resetAccessibilityLabel,
        SpokenPunctuationCopy.fieldAccessibilityLabel(languageName: "German"),
        SpokenPunctuationCopy.example(command: "Diktiere Punkt"),
      ] + refusals.map(SpokenPunctuationCopy.rejection)
    for s in strings {
      #expect(s.contains("\u{2014}") == false, "em-dash in user-facing copy: \(s)")
      #expect(s.contains("\u{2013}") == false, "en-dash in user-facing copy: \(s)")
    }
  }
}
