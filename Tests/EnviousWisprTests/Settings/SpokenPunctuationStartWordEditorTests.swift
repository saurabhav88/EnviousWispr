import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2450: the Start word row's editing behaviour, driven through the real editor and the real
/// `SettingsManager`, not a copy of either.
///
/// **Product Outcome.** When these fail a user types a start word and it is lost, is saved for the
/// wrong language, is saved although it breaks the rules, or leaves no reason on screen. Layout,
/// focus order and VoiceOver are not proven here; those wait for the hands-on pass in the dev app.
@MainActor
@Suite("Start word editor (#2450)", .tags(.productOutcome))
struct SpokenPunctuationStartWordEditorTests {

  private static func freshSettings() -> SettingsManager {
    SettingsManager(defaults: TestDefaults.suite("SW-2450-\(UUID().uuidString)")!)
  }

  private final class Counter: @unchecked Sendable {
    var changes = 0
  }

  // MARK: - Which language opens

  @Test("The picker opens on the locked language when it has a table, otherwise German")
  func initialLanguage() {
    let cases: [(LanguageMode, String)] = [
      (.locked("fr"), "fr"), (.locked("es"), "es"), (.locked("it"), "it"),
      (.locked("de-DE"), "de"), (.locked("en"), "de"), (.locked("nl"), "de"), (.auto, "de"),
    ]
    for (mode, expected) in cases {
      let settings = Self.freshSettings()
      settings.languageMode = mode
      #expect(
        SpokenPunctuationStartWordEditor(settings: settings).language == expected,
        "mode \(mode)")
    }
  }

  @Test("Picking a language never changes the dictation language")
  func pickerLeavesDictationLanguageAlone() {
    let settings = Self.freshSettings()
    settings.languageMode = .locked("en")
    let editor = SpokenPunctuationStartWordEditor(settings: settings)
    editor.selectLanguage("fr")
    #expect(settings.languageMode == .locked("en"))
  }

  @Test("A language without a table cannot be picked")
  func unsupportedLanguageIsIgnored() {
    let editor = SpokenPunctuationStartWordEditor(settings: Self.freshSettings())
    editor.selectLanguage("nl")
    #expect(editor.language == "de")
  }

  // MARK: - What the row shows

  @Test("It shows the default word and a command built from the rules for every language")
  func defaultsAndExamples() throws {
    let expected = [
      "de": "Diktiere", "fr": "Place", "es": "Añade", "it": "Metti",
    ]
    for code in SpokenPunctuationStartWordEditor.languages {
      let editor = SpokenPunctuationStartWordEditor(settings: Self.freshSettings())
      editor.selectLanguage(code)
      #expect(editor.effectiveWord == expected[code])
      #expect(editor.draft == expected[code])
      let form = try #require(
        SpokenPunctuationRules.rules(for: code)?.first { $0.command == .period }?.spokenForms.first)
      #expect(editor.exampleCommand == "\(try #require(expected[code])) \(form)")
      #expect(editor.isCustomised == false)
    }
  }

  // MARK: - Commit

  @Test("A valid word is stored for the picked language and the field shows the stored form")
  func validCommit() {
    let settings = Self.freshSettings()
    let editor = SpokenPunctuationStartWordEditor(settings: settings)
    editor.userEdited("  Sprich ")
    editor.commitDraft()
    #expect(settings.spokenPunctuation.startWordOverrides == ["de": "Sprich"])
    #expect(editor.effectiveWord == "Sprich")
    #expect(editor.draft == "Sprich")
    #expect(editor.rejection == nil)
    #expect(editor.isCustomised)
    #expect(editor.exampleCommand == "Sprich Punkt")
  }

  @Test("A word equal to the default is stored as no word of the user's own")
  func defaultWordIsNotACustomisation() {
    let settings = Self.freshSettings()
    let editor = SpokenPunctuationStartWordEditor(settings: settings)
    editor.userEdited("diktiere")
    editor.commitDraft()
    #expect(settings.spokenPunctuation.startWordOverrides.isEmpty)
    #expect(editor.isCustomised == false)
    #expect(editor.draft == "Diktiere")
  }

  @Test("Every refusal reverts the field, keeps the stored word and shows its reason")
  func everyRefusalReverts() {
    let cases: [(String, SpokenPunctuationStartWord.Refusal)] = [
      ("zwei Worte", .notOneToken),
      ("Setze1", .invalidCharacters),
      ("a", .tooShort),
      (String(repeating: "x", count: 21), .tooLong),
      ("Punkt", .collidesWithCommand),
    ]
    for (input, reason) in cases {
      let settings = Self.freshSettings()
      let editor = SpokenPunctuationStartWordEditor(settings: settings)
      editor.userEdited("Sprich")
      editor.commitDraft()
      editor.userEdited(input)
      editor.commitDraft()
      #expect(editor.rejection == reason, "input \(input.debugDescription)")
      #expect(editor.draft == "Sprich", "input \(input.debugDescription)")
      #expect(settings.spokenPunctuation.startWordOverrides == ["de": "Sprich"])
    }
  }

  @Test("The settings store refuses a language with no table, and the copy has words for it")
  func unsupportedLanguageRefusal() {
    let settings = Self.freshSettings()
    let outcome = settings.commitSpokenPunctuationStartWord("Wort", language: "nl")
    #expect(outcome == .refused(.unsupportedLanguage))
    #expect(SpokenPunctuationCopy.rejection(.unsupportedLanguage).isEmpty == false)
    #expect(settings.spokenPunctuation.startWordOverrides.isEmpty)
  }

  @Test("Typing clears the reason shown for the earlier input")
  func typingClearsTheReason() {
    let editor = SpokenPunctuationStartWordEditor(settings: Self.freshSettings())
    editor.userEdited("a")
    editor.commitDraft()
    #expect(editor.rejection == .tooShort)
    editor.userEdited("Dik")
    #expect(editor.rejection == nil)
  }

  // MARK: - Return, then focus loss

  @Test("Return followed by the focus loss it causes saves once and keeps the reason on screen")
  func returnThenFocusLoss() {
    let settings = Self.freshSettings()
    let counter = Counter()
    settings.onChange = { _ in counter.changes += 1 }
    let editor = SpokenPunctuationStartWordEditor(settings: settings)

    editor.userEdited("Sprich")
    editor.commitDraft()
    editor.commitDraft()
    #expect(counter.changes == 1, "one commit, one persisted change")
    #expect(settings.spokenPunctuation.startWordOverrides == ["de": "Sprich"])

    editor.userEdited("a")
    editor.commitDraft()
    editor.commitDraft()
    #expect(editor.rejection == .tooShort, "the second commit must not hide the reason")
    #expect(counter.changes == 1, "a refused word persists nothing")
  }

  // MARK: - Switching language

  @Test("Switching language keeps a valid draft for the language it was typed for")
  func switchKeepsAValidDraftForTheOldLanguage() {
    let settings = Self.freshSettings()
    let editor = SpokenPunctuationStartWordEditor(settings: settings)
    editor.userEdited("Sprich")
    editor.selectLanguage("fr")
    #expect(settings.spokenPunctuation.startWordOverrides == ["de": "Sprich"])
    #expect(editor.language == "fr")
    #expect(editor.draft == "Place")
    #expect(editor.rejection == nil)
  }

  @Test("Switching language drops an invalid draft and never applies it to the new language")
  func switchDropsAnInvalidDraft() {
    let settings = Self.freshSettings()
    let editor = SpokenPunctuationStartWordEditor(settings: settings)
    editor.userEdited("zwei Worte")
    editor.selectLanguage("es")
    #expect(settings.spokenPunctuation.startWordOverrides.isEmpty)
    #expect(editor.draft == "Añade")
    #expect(editor.rejection == nil, "the reason was about the old language's input")
  }

  @Test("A valid draft is never saved under the new language")
  func switchNeverCrossesLanguages() {
    let settings = Self.freshSettings()
    let editor = SpokenPunctuationStartWordEditor(settings: settings)
    editor.userEdited("Sprich")
    editor.selectLanguage("it")
    #expect(settings.spokenPunctuation.startWordOverrides["it"] == nil)
    #expect(settings.spokenPunctuation.startWordOverrides["de"] == "Sprich")
  }

  // MARK: - Reset

  @Test("Reset puts the default back, refreshes the field and clears the reason")
  func resetRestoresTheDefault() {
    let settings = Self.freshSettings()
    let editor = SpokenPunctuationStartWordEditor(settings: settings)
    editor.userEdited("Sprich")
    editor.commitDraft()
    editor.userEdited("a")
    editor.commitDraft()
    #expect(editor.rejection != nil)

    editor.reset()
    #expect(settings.spokenPunctuation.startWordOverrides.isEmpty)
    #expect(editor.draft == "Diktiere")
    #expect(editor.rejection == nil)
    #expect(editor.isCustomised == false)
    #expect(editor.exampleCommand == "Diktiere Punkt")
  }

  @Test("Reset changes only the picked language")
  func resetIsPerLanguage() {
    let settings = Self.freshSettings()
    settings.commitSpokenPunctuationStartWord("Sprich", language: "de")
    settings.commitSpokenPunctuationStartWord("Schreibe", language: "fr")
    let editor = SpokenPunctuationStartWordEditor(settings: settings)
    editor.reset()
    #expect(settings.spokenPunctuation.startWordOverrides == ["fr": "Schreibe"])
  }

  // MARK: - The row leaving

  @Test("When the row leaves, a valid draft is saved for its own language")
  func leavingSavesAValidDraft() {
    let settings = Self.freshSettings()
    let editor = SpokenPunctuationStartWordEditor(settings: settings)
    editor.selectLanguage("fr")
    editor.userEdited("Dictée")
    editor.settleBeforeLeaving()
    #expect(settings.spokenPunctuation.startWordOverrides == ["fr": "Dictée"])
  }

  @Test("When the row leaves, an invalid draft is dropped")
  func leavingDropsAnInvalidDraft() {
    let settings = Self.freshSettings()
    let editor = SpokenPunctuationStartWordEditor(settings: settings)
    editor.userEdited("zwei Worte")
    editor.settleBeforeLeaving()
    #expect(settings.spokenPunctuation.startWordOverrides.isEmpty)
  }

  @Test("The no-start-word warning shows for a blank draft before it is committed")
  func warningShowsForABlankDraft() {
    let settings = Self.freshSettings()
    let editor = SpokenPunctuationStartWordEditor(settings: settings)
    #expect(editor.showsNoStartWordWarning == false)
    editor.userEdited("")
    #expect(editor.hasNoStartWord == false, "nothing is committed yet")
    #expect(editor.showsNoStartWordWarning)
    editor.userEdited("Sprich")
    #expect(editor.showsNoStartWordWarning == false)
  }

  @Test("A blank field is the choice of no start word, and Reset brings the default back")
  func blankFieldMeansNoStartWord() {
    let settings = Self.freshSettings()
    let editor = SpokenPunctuationStartWordEditor(settings: settings)
    editor.userEdited("   ")
    editor.commitDraft()
    #expect(editor.rejection == nil)
    #expect(editor.hasNoStartWord)
    #expect(editor.draft == "")
    #expect(editor.isCustomised)
    #expect(settings.spokenPunctuation.startWordOverrides == ["de": ""])
    #expect(editor.exampleCommand == "Punkt")

    editor.reset()
    #expect(editor.hasNoStartWord == false)
    #expect(editor.draft == "Diktiere")
    #expect(settings.spokenPunctuation.startWordOverrides.isEmpty)
  }
}
