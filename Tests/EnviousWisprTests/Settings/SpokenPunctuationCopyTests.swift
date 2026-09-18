import Testing

@testable import EnviousWisprAppKit

/// #1794: the in-app help panel's word list is a HAND-MAINTAINED mirror of
/// `InverseTextNormalizer.punct`. Nothing derives one from the other at runtime, so this
/// freeze test is the guard: if someone edits the copy, it must be a conscious act, and if
/// someone edits the rules the mismatch shows up here rather than in a panel that
/// quietly lies to users about what the app does.
struct SpokenPunctuationCopyTests {

  /// One tuple can yield more than one phrase (`exclamation (mark|point)`, optional "forward");
  /// the two-word "back slash" alias is deliberately not a row.
  @Test("The help panel lists exactly the spoken phrases, verbatim and in order")
  func phrasesAreFrozen() {
    let expected: [(String, String)] = [
      ("comma", ","),
      ("period", "."),
      ("full stop", "."),
      ("question mark", "?"),
      ("exclamation mark", "!"),
      ("exclamation point", "!"),
      ("colon", ":"),
      ("semicolon", ";"),
      // #3038: "slash" and "forward slash" left this table; the slash converts in both switch
      // positions and the footnote below says so.
      ("backslash", "\\"),
      ("new line", "a line break"),
      ("new paragraph", "a blank line"),
    ]
    #expect(SpokenPunctuationCopy.phrases.count == expected.count)
    for (actual, want) in zip(SpokenPunctuationCopy.phrases, expected) {
      #expect(actual.spoken == want.0, "spoken phrase drifted: \(actual.spoken) vs \(want.0)")
      #expect(actual.result == want.1, "result copy drifted for \(actual.spoken)")
    }
  }

  /// The panel is keyed by `spoken` through `Identifiable`, so a duplicate would silently
  /// collapse a row in the `ForEach` and hide a phrase from users.
  @Test("Spoken phrases are unique so no row is dropped from the panel")
  func spokenPhrasesAreUnique() {
    let spoken = SpokenPunctuationCopy.phrases.map(\.spoken)
    #expect(Set(spoken).count == spoken.count, "duplicate spoken phrase would collapse a panel row")
  }

  /// #3038: the footnote is the only place the panel describes the always-on slash, so its exact
  /// wording is pinned: the three shapes (a command, a command in a sentence, a pair), the verb
  /// that stays words, and the non-categorical "can still" for the known miss.
  @Test("The footnote describes the always-on slash without a categorical promise")
  func footnoteIsFrozen() {
    #expect(
      SpokenPunctuationCopy.helpFootnote
        == "These words become marks even when you meant the word itself, like \"the grace "
        + "period expires\". Slash works with this setting off: \"slash clear\" becomes /clear, "
        + "\"command is slash wfp\" becomes command is /wfp, \"pros slash cons\" becomes "
        + "pros/cons, and \"slash the budget\" stays words. Some verb uses, like \"slash prices\", "
        + "can still become a symbol.")
    #expect(SpokenPunctuationCopy.helpFootnote.contains("always") == false)
  }

  /// Brand rule: no em-dashes or en-dashes in user-facing copy.
  @Test("User-facing strings carry no em-dash or en-dash")
  func noDashes() {
    let strings =
      [
        SpokenPunctuationCopy.toggleLabel,
        SpokenPunctuationCopy.toggleDescription,
        SpokenPunctuationCopy.helpButtonAccessibilityLabel,
        SpokenPunctuationCopy.helpTitle,
        SpokenPunctuationCopy.helpSayColumn,
        SpokenPunctuationCopy.helpGetColumn,
        SpokenPunctuationCopy.helpFootnote,
      ] + SpokenPunctuationCopy.phrases.flatMap { [$0.spoken, $0.result] }
    for s in strings {
      #expect(s.contains("\u{2014}") == false, "em-dash in user-facing copy: \(s)")
      #expect(s.contains("\u{2013}") == false, "en-dash in user-facing copy: \(s)")
    }
  }
}
