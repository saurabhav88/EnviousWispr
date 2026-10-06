import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Observation

/// #2450: the editing state behind the "Start word" row.
///
/// The row edits ONE language's start word at a time. This model owns the draft text and the picked
/// language, and every change to the stored word goes through `SettingsManager`'s
/// `commitSpokenPunctuationStartWord` and `resetSpokenPunctuationStartWord`, so validation and
/// persistence have exactly one owner. The model never decides whether a word is acceptable.
///
/// The draft is kept apart from the stored value on purpose: the field shows what the user is typing,
/// and only a commit (Return, the Save button, losing focus, switching language, or the row leaving) writes it.
///
/// The picker is not the dictation language. It only chooses which table's start word is being
/// edited, so changing it never touches `languageMode`.
@MainActor
@Observable
final class SpokenPunctuationStartWordEditor {

  /// The languages with a table, in the order the picker lists them.
  static let languages = SpokenPunctuationRules.startWordLanguages

  /// English is most people's dictation language and is first in the picker, so it is the choice when
  /// the dictation language gives no better one. The Mac's region is deliberately not consulted.
  static let fallbackLanguage = "en"

  private let settings: SettingsManager

  /// The language whose start word is being edited. Always one of `languages`.
  private(set) var language: String

  /// What the field shows. Written by the user through `userEdited(_:)` and by this model when it
  /// settles a commit or loads a language.
  private(set) var draft: String

  /// Why the last commit was refused, or `nil`. Cleared by an accepted commit, a reset, a language
  /// switch and the next keystroke, never by a commit that changed nothing, so Return followed by
  /// the focus loss it causes does not hide the message the first one showed.
  private(set) var rejection: SpokenPunctuationStartWord.Refusal?

  init(settings: SettingsManager) {
    self.settings = settings
    let initial = Self.initialLanguage(for: settings.languageMode)
    self.language = initial
    self.draft = Self.effectiveWord(for: initial, settings: settings)
  }

  /// The language's name in the interface language, for the picker and the field's spoken name.
  static func displayName(for code: String) -> String {
    Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
  }

  /// The offered language the dictation language is locked to, otherwise English.
  static func initialLanguage(for mode: LanguageMode) -> String {
    if case .locked(let code) = mode,
      let base = LanguageNormalizer.baseCode(code),
      languages.contains(base)
    {
      return base
    }
    return fallbackLanguage
  }

  private static func effectiveWord(for language: String, settings: SettingsManager) -> String {
    SpokenPunctuationRules.effectiveStartWords(
      overrides: settings.spokenPunctuation.startWordOverrides)[
        language] ?? ""
  }

  // MARK: - What the row shows

  /// The start word in force for the picked language: the user's word, else the shipped default.
  var effectiveWord: String { Self.effectiveWord(for: language, settings: settings) }

  /// The start word in force for ANY supported language, `""` when its field is blank. The language
  /// dropdown shows it under each language's name.
  func startWord(for code: String) -> String { Self.effectiveWord(for: code, settings: settings) }

  /// True while the picked language has NO start word, the user's choice of a blank field.
  var hasNoStartWord: Bool { effectiveWord.isEmpty }

  /// True while the stored word is blank OR the field is blank and not yet committed, so the warning
  /// is on screen before a blank can be committed by switching language or leaving the page.
  var showsNoStartWordWarning: Bool {
    hasNoStartWord || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// True while the field shows text that is not yet the stored word, which is when Save does something.
  var hasUnsavedDraft: Bool { draft != effectiveWord }

  /// True while the picked language has a word of the user's own, which is when Reset does something.
  var isCustomised: Bool { settings.spokenPunctuation.startWordOverrides[language] != nil }

  /// True while Reset has something to undo: a word of the user's own, a typed draft, or a refusal
  /// message still on screen.
  var canReset: Bool { isCustomised || hasUnsavedDraft || rejection != nil }

  /// A spoken command that inserts a period in the picked language, built from the rules table so the
  /// example can never name a word the pass does not accept. It stays in the dictation language.
  var exampleCommand: String? {
    guard
      let form = SpokenPunctuationRules.startWordRules(for: language)?.first(where: { $0.command == .period }
      )?
      .spokenForms.first
    else { return nil }
    return effectiveWord.isEmpty ? form : effectiveWord + " " + form
  }

  // MARK: - Editing

  /// The user typed. Clears a stale rejection so the message never outlives the input it was about.
  func userEdited(_ text: String) {
    draft = text
    rejection = nil
  }

  /// Return, or the field losing focus. Writes the draft for the picked language, or puts the last
  /// good word back and says why.
  func commitDraft() {
    // Nothing to write when the field already shows the stored word, which is what the second of
    // "Return, then focus loss" sees. Leaving the rejection alone here is what keeps it on screen.
    guard hasUnsavedDraft else { return }
    switch settings.commitSpokenPunctuationStartWord(draft, language: language) {
    case .accepted:
      rejection = nil
    case .refused(let reason):
      rejection = reason
    }
    draft = effectiveWord
  }

  /// A new language was picked. The old language's draft is settled first, against the OLD language,
  /// so a valid word is kept and an invalid one is dropped; only then does the new language load.
  func selectLanguage(_ new: String) {
    guard Self.languages.contains(new), new != language else { return }
    commitDraft()
    language = new
    draft = effectiveWord
    rejection = nil
  }

  /// Put the picked language back on its default word.
  func reset() {
    settings.resetSpokenPunctuationStartWord(language: language)
    draft = effectiveWord
    rejection = nil
  }

  /// The row is leaving, because the switch turned off or the page closed. A pending draft is settled
  /// for the language it was typed for, never carried into another one.
  func settleBeforeLeaving() {
    commitDraft()
  }
}
