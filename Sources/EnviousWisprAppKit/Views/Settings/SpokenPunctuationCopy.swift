import Foundation

/// #1794: canonical copy for the spoken-punctuation setting and its in-app help panel.
///
/// `phrases` is a HAND-MAINTAINED mirror of `InverseTextNormalizer.punct` plus the backslash
/// half of its `joinerCommands` sibling (one rule can yield more than one spoken phrase:
/// `exclamation (mark|point)` does; the two-word "back slash" alias is accepted but not
/// listed). The spoken SLASH is not in this table since #3038: it converts in both switch
/// positions (`InverseTextNormalizer.slashReading`), so the panel, which documents what the
/// setting does, describes it in the footnote instead. The regex table
/// is `private` and deliberately stays that way: deriving this list from it at runtime
/// would mean widening the engine's internals across a module boundary to render a
/// static help panel. The cost of the mirror is drift; the guard is
/// `SpokenPunctuationCopyTests`, which pins every pair verbatim, plus a comment on the
/// `punct` table pointing back here. Change the rules, change this list.
///
/// No em-dashes or en-dashes (brand rule).
enum SpokenPunctuationCopy {
  static let toggleLabel = String(
    localized: "Convert spoken punctuation",
    comment: "Speech engine settings, spoken punctuation: the toggle's name.")
  static let toggleDescription =
    String(
      localized:
        "Say punctuation out loud to insert it. EnviousWispr already adds punctuation for you, so this can compete with it.",
      comment: "Speech engine settings, spoken punctuation: description under the toggle.")

  static let helpButtonAccessibilityLabel = String(
    localized: "What can I say?",
    comment: "Speech engine settings, spoken punctuation: VoiceOver name of the help button.")
  static let helpTitle = String(
    localized: "Words you can say",
    comment: "Speech engine settings, spoken punctuation: help panel title.")
  static let helpSayColumn = String(
    localized: "Say this",
    comment:
      "Speech engine settings, spoken punctuation: help table column: the words the user says.")
  static let helpGetColumn = String(
    localized: "You get",
    comment:
      "Speech engine settings, spoken punctuation: help table column: what appears in the text.")
  /// Closing note in the panel: names the failure mode a user will otherwise discover
  /// by having a sentence quietly broken.
  static let helpFootnote =
    String(
      localized:
        "These words become marks even when you meant the word itself, like \"the grace period expires\". Slash works with this setting off: \"slash clear\" becomes /clear, \"command is slash wfp\" becomes command is /wfp, \"pros slash cons\" becomes pros/cons, and \"slash the budget\" stays words. Some verb uses, like \"slash prices\", can still become a symbol.",
      comment:
        "Speech engine settings, spoken punctuation: help panel footnote. The quoted phrases are English words the user says to dictation; keep them in English, and keep /clear, /wfp and pros/cons exactly."
    )

  /// Spoken phrase paired with what the user sees. Order is the order shown.
  /// `result` is display copy, not the literal replacement: "new line" inserts a real
  /// line break, which cannot be rendered meaningfully in a table cell. `spoken` is what the
  /// dictation engine accepts, so it stays in the dictation language, never translated; a
  /// result that is a word ("a line break") is interface text and is localized (#3142).
  struct Phrase: Identifiable, Equatable {
    let spoken: String
    let result: String
    var id: String { spoken }
  }

  static let phrases: [Phrase] = [
    Phrase(spoken: "comma", result: ","),
    Phrase(spoken: "period", result: "."),
    Phrase(spoken: "full stop", result: "."),
    Phrase(spoken: "question mark", result: "?"),
    Phrase(spoken: "exclamation mark", result: "!"),
    Phrase(spoken: "exclamation point", result: "!"),
    Phrase(spoken: "colon", result: ":"),
    Phrase(spoken: "semicolon", result: ";"),
    Phrase(spoken: "backslash", result: "\\"),
    Phrase(
      spoken: "new line",
      result: String(
        localized: "a line break",
        comment:
          "Speech engine settings, spoken punctuation: what a spoken command produces, shown in the help table's result column."
      )),
    Phrase(
      spoken: "new paragraph",
      result: String(
        localized: "a blank line",
        comment:
          "Speech engine settings, spoken punctuation: what a spoken command produces, shown in the help table's result column."
      )),
  ]
}
