import Foundation

/// The comparison form for snippet matching, and the ONE place it is defined (#628).
///
/// Lives in Core rather than beside the matcher in PostProcessing because three callers need
/// the identical answer and they are in different modules: `SnippetExpander` (matching),
/// the edit sheet (refusing a duplicate trigger), and import comparison. A second
/// implementation is how two of them come to disagree about whether "My Email." and
/// "my email" are the same trigger.
///
/// Ported from the approved design prototype's `norm()`
/// (`docs/feature-requests/issue-628-design/EnviousWispr Snippets.dc.html`): lowercase, drop a
/// leading opening bracket or quote, drop trailing sentence punctuation. Everything else
/// compares literally — this is deliberately NOT fuzzy, unlike `WordCorrector`.
public enum SnippetText {
  /// Punctuation dropped from the FRONT of a spoken token before comparison.
  static let leading: Set<Character> = ["(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}"]

  /// Punctuation dropped from the END of a spoken token before comparison. This is also the
  /// set `SnippetExpander` re-attaches AFTER an expansion, so a full stop that clung to the
  /// last trigger word survives the substitution. The two uses share this one list on purpose:
  /// a token stripped here and not re-attached there would silently eat the user's punctuation.
  public static let trailing: Set<Character> = [
    ".", ",", "!", "?", ";", ":", ")", "]", "}", "\"", "'", "\u{201D}", "\u{2019}",
  ]

  /// A spoken token reduced to its comparison form.
  ///
  /// Whitespace is trimmed at BOTH ends, and that is not redundant with the tokeniser: the
  /// keyword arrives from a text field the user types into, not from splitting a transcript.
  /// Without the trim a keyword of "   " normalises to "   ", which is non-empty, so
  /// `SnippetVocabulary.canFire` reports true and the expansion step arms itself against a
  /// keyword nobody can speak. Caught by its own test rather than by a user.
  ///
  /// The order matters: trim, then strip punctuation, then trim again, so ' "hello" ' and
  /// '"hello"' reach the same form.
  public static func normalize(_ token: String) -> String {
    var s = Substring(token.lowercased()).trimmingWhitespace()
    while let first = s.first, leading.contains(first) { s = s.dropFirst() }
    while let last = s.last, trailing.contains(last) { s = s.dropLast() }
    return String(s.trimmingWhitespace())
  }

  /// Punctuation that ENDS a sentence. A subset of `trailing`, and the distinction matters: a
  /// comma inside a matched phrase is noise, a full stop is a boundary.
  public static let sentenceEnding: Set<Character> = [".", "!", "?"]

  /// True when this token ends a sentence.
  public static func endsSentence(_ token: String) -> Bool {
    guard let last = token.last else { return false }
    return sentenceEnding.contains(last)
  }

  /// The leading punctuation run on a token, in source order.
  ///
  /// Its partner below handles the end of the trigger; this handles the start of the KEYWORD.
  /// Both are needed, and having only one is a silent loss: in a quoted phrase the opening
  /// quote is stripped so the keyword can match, and without restoring it the user gets the
  /// pasted text with a closing quote and no opening one.
  public static func leadingPunctuation(_ token: String) -> String {
    var run: [Character] = []
    var s = Substring(token)
    while let first = s.first, leading.contains(first) {
      run.append(first)
      s = s.dropFirst()
    }
    return String(run)
  }

  /// The trailing punctuation run on a token, in source order — what `normalize` removed from
  /// the end and what the expansion must carry forward.
  public static func trailingPunctuation(_ token: String) -> String {
    var run: [Character] = []
    var s = Substring(token)
    while let last = s.last, trailing.contains(last) {
      run.append(last)
      s = s.dropLast()
    }
    return String(run.reversed())
  }
}

extension Substring {
  /// Whitespace-only trim on a `Substring`, so `SnippetText.normalize` never copies the string
  /// twice just to trim it.
  fileprivate func trimmingWhitespace() -> Substring {
    var s = self
    while let first = s.first, first.isWhitespace { s = s.dropFirst() }
    while let last = s.last, last.isWhitespace { s = s.dropLast() }
    return s
  }
}

/// One voice-triggered text expansion (#628).
///
/// A snippet fires only when the user speaks their keyword (`SnippetVocabulary.keyword`,
/// default "backslash") immediately before `trigger`, and `trigger` matches word for word.
/// `expansion` is then delivered byte-for-byte — it is masked behind a per-run sentinel so
/// AI Polish never sees it, and `SnippetFinalizer` substitutes it back before anything is
/// stored or delivered.
///
/// Deliberately NOT a `CustomWord` variant. `CustomWord` repairs what the speech engine
/// misheard and matches FUZZILY on purpose (`WordCorrector`'s six passes); a snippet trigger
/// must be literal, or "my email address" spoken in ordinary prose starts pasting an address.
/// #630 argued that separation and the approved design settles it by giving Snippets its own
/// surface.
public struct Snippet: Codable, Identifiable, Sendable, Hashable {
  public let id: UUID
  /// The words spoken after the keyword. Matched word for word after normalisation, never fuzzily.
  public var trigger: String
  /// The text delivered in the trigger's place, exactly as the user typed it, newlines included.
  public var expansion: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    trigger: String,
    expansion: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.trigger = trigger
    self.expansion = expansion
    self.createdAt = createdAt
  }

  /// The trigger's comparison form: the tokens the matcher compares against, in order.
  public var triggerTokens: [String] {
    trigger
      .split(whereSeparator: { $0.isWhitespace })
      .map { SnippetText.normalize(String($0)) }
      .filter { !$0.isEmpty }
  }

  /// True when both snippets would be matched by the same spoken words. The duplicate rule,
  /// stated once, so the edit sheet, import, and any future caller cannot drift apart.
  public func collidesWith(_ other: Snippet) -> Bool {
    let mine = triggerTokens
    return !mine.isEmpty && mine == other.triggerTokens
  }
}
