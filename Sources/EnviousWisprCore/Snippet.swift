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

  /// Punctuation that CLOSES rather than terminates: a bracket or a quote that can sit AFTER a
  /// full stop and hide it from anything reading only a token's last character (#2605).
  public static let closing: Set<Character> = [")", "]", "}", "\"", "'", "\u{201D}", "\u{2019}"]

  /// Punctuation dropped from the END of a spoken token before comparison. `SnippetExpander`
  /// normally re-attaches the same run after the expansion, so a full stop that clung to the
  /// last trigger word survives the substitution; a SENTENCE ending is suppressed instead when
  /// the snippet owns its ending (#2637). The two uses share this one list on purpose: a token
  /// stripped here and re-attached from a different list there would drift.
  ///
  /// Composed from the three ROLES rather than spelled out, so the roles cannot drift apart.
  /// Before #2605 `closing` was a hand-copied subset of a literal list here, which is how a
  /// closing quote came to be strippable for matching and invisible to `endsSentence` at the
  /// same time. Membership is pinned by a literal in `SnippetTextPunctuationSetTests`.
  public static let trailing: Set<Character> =
    sentenceEnding.union(closing).union([",", ";", ":"])

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
  ///
  /// Reads THROUGH trailing whitespace and closing marks rather than at the final character
  /// (#2605). `my.\u{201D}` ends a sentence; its last character is the quote. The two callers
  /// need that for different reasons and both failed the same way: the boundary guard let a
  /// snippet span a real sentence break, and the trailing-punctuation decision could not see
  /// that a saved expansion already terminated itself.
  ///
  /// Whitespace first, because a saved expansion is deliberately NOT trimmed (`SnippetEditSheet`
  /// keeps a trailing newline that a user meant), so `Saurabh\n` must answer for `Saurabh`.
  public static func endsSentence(_ token: String) -> Bool {
    var s = Substring(token).trimmingWhitespace()
    while let last = s.last, closing.contains(last) { s = s.dropLast() }
    guard let last = s.last else { return false }
    return sentenceEnding.contains(last)
  }

  /// The maximal run of trailing punctuation at the START of `s`.
  ///
  /// The mirror of `trailingPunctuation`, which reads from the END of a token. This direction
  /// exists because `SnippetFinalizer` looks FORWARD from a sentinel into text a model wrote,
  /// and it must see the WHOLE run before deciding anything — a loop that stops at the first
  /// non-terminator cannot see a full stop standing behind a bracket.
  public static func punctuationRunPrefix(of s: Substring) -> Substring {
    var end = s.startIndex
    while end < s.endIndex, trailing.contains(s[end]) { end = s.index(after: end) }
    return s[s.startIndex..<end]
  }

  /// A trailing-punctuation run with its sentence terminators removed and everything else kept,
  /// in source order.
  ///
  /// **This is the one answer to "a terminator can hide behind a closing mark", and every site
  /// that decides about a run calls it.** Three separate sites each grew their own version of
  /// that question and two of them got it wrong in the same way — reading only the last
  /// character, and stopping at the first closer — so the question is asked in one place now.
  /// A fourth site of this class is not another patch: it means the per-site handling comes out
  /// and the run is normalised once, at one point.
  public static func droppingSentenceEndings(from run: some StringProtocol) -> String {
    String(run.filter { !sentenceEnding.contains($0) })
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
