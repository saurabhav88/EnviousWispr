import Foundation

/// #1794: canonical copy for the spoken-punctuation setting and its in-app help panel.
///
/// `phrases` is a HAND-MAINTAINED mirror of `InverseTextNormalizer.punct` (nine rule
/// tuples, ten spoken phrases — `exclamation (mark|point)` yields two). The regex table
/// is `private` and deliberately stays that way: deriving this list from it at runtime
/// would mean widening the engine's internals across a module boundary to render a
/// static help panel. The cost of the mirror is drift; the guard is
/// `SpokenPunctuationCopyTests`, which pins every pair verbatim, plus a comment on the
/// `punct` table pointing back here. Change the rules, change this list.
///
/// No em-dashes or en-dashes (brand rule).
enum SpokenPunctuationCopy {
  static let toggleLabel = "Convert spoken punctuation"
  static let toggleDescription =
    "Say punctuation out loud to insert it. EnviousWispr already adds punctuation for "
    + "you, so this can compete with it."

  static let helpButtonAccessibilityLabel = "What can I say?"
  static let helpTitle = "Words you can say"
  static let helpSayColumn = "Say this"
  static let helpGetColumn = "You get"
  /// Closing note in the panel: names the failure mode a user will otherwise discover
  /// by having a sentence quietly broken.
  static let helpFootnote =
    "These words become marks even when you meant the word itself, like \"the grace "
    + "period expires\"."

  /// Spoken phrase paired with what the user sees. Order is the order shown.
  /// `result` is display copy, not the literal replacement: "new line" inserts a real
  /// line break, which cannot be rendered meaningfully in a table cell.
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
    Phrase(spoken: "new line", result: "a line break"),
    Phrase(spoken: "new paragraph", result: "a blank line"),
  ]
}
