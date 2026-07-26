import Testing

@testable import EnviousWisprAppKit

/// #1794: the in-app help panel's word list is a HAND-MAINTAINED mirror of
/// `InverseTextNormalizer.punct`. Nothing derives one from the other at runtime, so this
/// freeze test is the guard: if someone edits the copy, it must be a conscious act, and if
/// someone edits the nine rules the mismatch shows up here rather than in a panel that
/// quietly lies to users about what the app does.
struct SpokenPunctuationCopyTests {

  /// Nine rule tuples, TEN phrases: `exclamation (mark|point)` yields two.
  @Test("The help panel lists exactly the ten spoken phrases, verbatim and in order")
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
