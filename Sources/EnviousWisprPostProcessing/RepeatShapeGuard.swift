import Foundation

// MARK: - Repeat-learn shape guard (#3975 plan §3.2)
//
// A pair the judge refused, fixed again the same way in a later dictation, is
// learned without asking the judge only when the corrected spelling looks like
// a name, brand or term. A repeated everyday rewrite ("got" -> "received") must
// never become a learn, however often it is repeated. Closed question, no word
// list: a lowercase term keeps today's judge-only path.

package enum RepeatShapeGuard {

  /// True when the corrected run carries a capital letter that is not only a
  /// sentence-start capital ("CENIT", "Sify", "Kubernetes" mid-sentence,
  /// "TeamViewer"), or a token with a digit and a letter ("Tele2", "COP1"; a
  /// bare number never qualifies).
  /// - Parameters:
  ///   - corrected: the run's corrected core (`EditAlignment.Run.coreReplacement`).
  ///   - startToken: the run's first token index in `pasted`
  ///     (`EditAlignment.Run.originalRange.lowerBound`).
  ///   - pasted: the text the app pasted, which decides sentence start.
  package static func passes(corrected: String, startToken: Int, pasted: String) -> Bool {
    let atSentenceStart = isSentenceStart(tokenIndex: startToken, in: pasted)
    for (i, token) in InverseTextNormalizer.splitWords(corrected).enumerated() {
      if token.contains(where: \.isLetter), token.contains(where: \.isWholeNumber) { return true }
      // The first letter of the run's first token may be capital only
      // because a sentence starts there; any other capital counts.
      let counted = i == 0 && atSentenceStart ? token.dropFirst() : Substring(token)
      if counted.contains(where: \.isUppercase) { return true }
    }
    return false
  }

  /// Sentence terminators, including the ellipsis character.
  static let terminators: Set<Character> = [".", "!", "?", "…"]
  /// Closing quotes and brackets that may follow a terminator.
  static let closingMarks: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}"]

  /// The token at `tokenIndex` (whitespace-split, as `EditAlignment` splits)
  /// is the first token of `text`, or follows a token ending in `.`, `!`,
  /// `?` or `…` (closing quotes and brackets after it allowed), or follows a
  /// newline. An index past the end is not a sentence start.
  package static func isSentenceStart(tokenIndex: Int, in text: String) -> Bool {
    var index = 0
    var previous: Substring?
    var sawNewline = false
    var i = text.startIndex
    while i < text.endIndex {
      if text[i].isWhitespace {
        if text[i].isNewline { sawNewline = true }
        i = text.index(after: i)
        continue
      }
      let start = i
      while i < text.endIndex, !text[i].isWhitespace { i = text.index(after: i) }
      if index == tokenIndex {
        guard let previous else { return true }
        // A sentence can end inside quotes or brackets (`said "fine." Got`):
        // look past closing marks to the terminator.
        let end = previous.reversed().first { !Self.closingMarks.contains($0) }
        return sawNewline || end.map { Self.terminators.contains($0) } ?? false
      }
      previous = text[start..<i]
      sawNewline = false
      index += 1
    }
    return false
  }
}
