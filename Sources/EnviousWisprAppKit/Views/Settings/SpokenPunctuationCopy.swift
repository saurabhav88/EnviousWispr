import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// #1794, #2450: canonical copy for the spoken-punctuation setting, its "?" help and its Start word row.
///
/// The word list is not shown in the app. The Help Center article owns it, and the row shows only the
/// start word in force and one command built from the rules table, so there is no second inventory of
/// phrases here to drift from the rules. Spoken commands stay in the dictation language: they are what
/// the user says, never interface text, so they are interpolated into a localized sentence and not
/// translated themselves.
///
/// No em-dashes or en-dashes (brand rule).
enum SpokenPunctuationCopy {
  static let toggleLabel = String(
    localized: "Spoken punctuation",
    comment: "Speech engine settings, spoken punctuation: the toggle's name.")
  static let toggleDescription =
    String(
      localized:
        "Say punctuation out loud to insert it. EnviousWispr already adds punctuation for you, so this can compete with it.",
      comment: "Speech engine settings, spoken punctuation: description under the toggle.")

  // MARK: - "?" help for the toggle

  static let helpStartWord = String(
    localized:
      "In German, French, Spanish and Italian you say a start word first, then the mark. A command word on its own stays an ordinary word.",
    comment: "Speech engine settings, spoken punctuation help: how the start word works.")
  static let helpEnglish = String(
    localized: "English works as it does today: say the word on its own. You can also give English a start word.",
    comment: "Speech engine settings, spoken punctuation help: English needs no start word.")
  static let helpPolish = String(
    localized:
      "This is meant for dictating with AI polish off. AI polish can change punctuation afterwards.",
    comment: "Speech engine settings, spoken punctuation help: the setting is meant for polish off."
  )
  /// Names the failure mode a user will otherwise discover by having a sentence quietly broken, and
  /// the always-on slash, which does not depend on the switch (#3038).
  static let helpFootnote =
    String(
      localized:
        "In English these words become marks even when you meant the word itself, like \"the grace period expires\". Slash works with this setting off: \"slash clear\" becomes /clear, \"command is slash wfp\" becomes command is /wfp, \"pros slash cons\" becomes pros/cons, and \"slash the budget\" stays words. Some verb uses, like \"slash prices\", can still become a symbol.",
      comment:
        "Speech engine settings, spoken punctuation help footnote. The quoted phrases are English words the user says to dictation; keep them in English, and keep /clear, /wfp and pros/cons exactly."
    )
  static let learnMoreLabel = String(
    localized: "Learn more",
    comment: "Speech engine settings, spoken punctuation help: link to the Help Center article.")
  static let learnMoreAccessibilityLabel = String(
    localized: "Learn more about spoken punctuation",
    comment:
      "Speech engine settings, spoken punctuation help: spoken name of the Help Center link.")
  /// The Help Center article that owns the word list. The slug is pinned by the help article tests.
  static let learnMoreURL = URL(string: HelpCenter.rootURL + "spoken-punctuation-and-emoji/")

  // MARK: - Start word row

  static let startWordTitle = String(
    localized: "Start word",
    comment: "Speech engine settings, spoken punctuation: the Start word row's name.")
  static let startWordShort = String(
    localized:
      "The word you say before a mark. German, French, Spanish and Italian need one; English does not. Pick a word you would not say in a normal sentence.",
    comment: "Speech engine settings, Start word row: the short line under the row's name.")
  static let startWordHelp = String(
    localized:
      "Say your start word and then the mark. The start word is what tells a command from an ordinary word. You can set a different word for each language.",
    comment: "Speech engine settings, Start word row: the help behind the question mark.")
  static let startWordBlankHint = String(
    localized: "Leave it blank to use no start word.",
    comment: "Speech engine settings, Start word row: how to turn the start word off.")
  static let noStartWordWarning = String(
    localized:
      "Leaving this blank means no start word. Command words become marks wherever you say them, even inside a normal sentence.",
    comment:
      "Speech engine settings, Start word row: shown while the field is blank or its draft is blank, because every command word then becomes a mark."
  )
  static let noStartWordPlaceholder = String(
    localized: "No start word",
    comment: "Speech engine settings, Start word row: the blank field's placeholder, meaning no start word.")
  static let languagePickerLabel = String(
    localized: "Start word for",
    comment:
      "Speech engine settings, Start word row: label of the picker that chooses which language's start word is edited."
  )
  static let pickerIsNotDictationLanguage = String(
    localized:
      "This only picks which start word you edit. It does not change your dictation language.",
    comment:
      "Speech engine settings, Start word row: the language picker does not set the dictation language."
  )
  static let resetLabel = String(
    localized: "Reset",
    comment: "Speech engine settings, Start word row: button that restores the default start word.")
  static let resetAccessibilityLabel = String(
    localized: "Reset start word to the default",
    comment: "Speech engine settings, Start word row: spoken name of the Reset button.")

  /// Spoken name of the text field, which has no visible label of its own.
  static func fieldAccessibilityLabel(languageName: String) -> String {
    String(
      localized: "Start word for \(languageName)",
      comment:
        "Speech engine settings, Start word row: spoken name of the text field. The placeholder is a language name such as German."
    )
  }

  /// One command the picked language accepts, in the language the user dictates. The command is
  /// interpolated, never translated.
  static func example(command: String) -> String {
    String(
      localized: "Say \"\(command)\" to insert a period.",
      comment:
        "Speech engine settings, Start word row: an example. The placeholder is a spoken command in the dictation language, for example Diktiere Punkt; keep it exactly."
    )
  }

  /// The reason a word was refused, in plain words. One message per validator outcome; the validator
  /// stays the only place that decides.
  static func rejection(_ reason: SpokenPunctuationStartWord.Refusal) -> String {
    switch reason {
    case .empty:
      return String(
        localized: "Type a start word. The last one was kept.",
        comment: "Start word row: refusal shown when the field was left empty.")
    case .notOneToken:
      return String(
        localized: "Use one word, with no spaces. The last start word was kept.",
        comment: "Start word row: refusal shown when the text has more than one word.")
    case .invalidCharacters:
      return String(
        localized: "Use letters only. The last start word was kept.",
        comment: "Start word row: refusal shown when the text has digits or symbols.")
    case .tooShort:
      return String(
        localized: "Use at least \(SpokenPunctuationStartWord.minimumLength) letters. The last start word was kept.",
        comment: "Start word row: refusal shown when the word is too short.")
    case .tooLong:
      return String(
        localized: "Use at most \(SpokenPunctuationStartWord.maximumLength) letters. The last start word was kept.",
        comment: "Start word row: refusal shown when the word is too long.")
    case .collidesWithCommand:
      return String(
        localized: "That word is already a command word. The last start word was kept.",
        comment:
          "Start word row: refusal shown when the word is itself a spoken punctuation command.")
    case .unsupportedLanguage:
      return String(
        localized: "This language has no start word. Nothing was changed.",
        comment: "Start word row: refusal shown when the language has no spoken punctuation table.")
    }
  }
}
