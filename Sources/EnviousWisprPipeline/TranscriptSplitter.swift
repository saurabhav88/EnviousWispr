import Foundation
import NaturalLanguage

/// #2648 — cuts one long transcript into the parts the cleanup chain runs on.
///
/// **The 500-word ceiling is a correctness constraint, not a preference.** It
/// was measured on 2026-09-04: word correction takes 1,162 ms of its 3 s budget
/// at 500 words and 13,565 ms at 6,000, which is over. Polish quality falls off
/// the same way — a whole 45-minute transcript handed to either on-device
/// polisher came back at 53% and 50%, both truncated, while the same transcript
/// in parts held 96 to 97%. So a part that exceeds the ceiling does not merely
/// run slowly; it silently loses the end of the user's words.
///
/// **Sentences first, words only as a fallback.** Cutting mid-sentence hands the
/// polisher half a thought and it rewrites what it can see, so the join reads
/// like two people talking. `NLTokenizer` finds the real boundaries, including
/// for languages whose sentences do not end in a full stop. Only a single
/// sentence longer than the whole ceiling — a run-on, which is exactly what
/// unpunctuated ASR output produces — is cut at word boundaries, because at that
/// point there is no better cut available.
///
/// **A part is a verbatim slice of the input.** The splitter never rewrites,
/// normalises or re-spaces anything: whatever the engine produced is what the
/// cleanup chain sees. `TranscriptSplitterTests` asserts the round trip word for
/// word, in order, with nothing duplicated and nothing dropped.
public enum TranscriptSplitter {

  /// The ceiling every non-empty part obeys. Raising it narrows the promise
  /// above, and the measurement that set it is named there rather than here so
  /// there is one place to re-read before changing it.
  public static let maximumWordsPerPart = 500

  /// Splits `transcript` into parts of 1...`maximumWordsPerPart` words.
  ///
  /// Returns an empty array for a transcript with no words at all, which is the
  /// honest answer: there is nothing to clean. A caller that wants to say "no
  /// speech found" reads that from the empty result rather than from a part
  /// containing only whitespace.
  public static func split(_ transcript: String) -> [String] {
    let sentences = sentenceRanges(in: transcript)
    var parts: [String] = []
    var pending: [Substring] = []
    var pendingWords = 0

    func flushPending() {
      guard !pending.isEmpty else { return }
      // Sliced from the FIRST pending sentence's start to the LAST one's end, so
      // the part keeps the original spacing between those sentences rather than
      // a re-joined approximation of it.
      let lower = pending.first!.startIndex
      let upper = pending.last!.endIndex
      parts.append(String(transcript[lower..<upper]))
      pending = []
      pendingWords = 0
    }

    for range in sentences {
      let sentence = transcript[range]
      let words = wordCount(in: sentence)
      guard words > 0 else { continue }

      if words > maximumWordsPerPart {
        // A single sentence over the ceiling. Everything already packed goes
        // first, so the run-on's own cuts do not swallow the sentences before
        // it, and the run-on is then cut at word boundaries.
        flushPending()
        parts.append(contentsOf: splitAtWordBoundaries(sentence))
        continue
      }

      if pendingWords + words > maximumWordsPerPart { flushPending() }
      pending.append(sentence)
      pendingWords += words
    }
    flushPending()
    return parts
  }

  // MARK: - Boundaries

  /// Sentence ranges, from `NLTokenizer` rather than from a punctuation rule.
  ///
  /// A punctuation rule is the proxy here: it agrees with sentence structure for
  /// English prose and disagrees for an abbreviation, a decimal number, and every
  /// script that does not use a full stop. The tokenizer answers the question
  /// itself.
  private static func sentenceRanges(in text: String) -> [Range<String.Index>] {
    guard !text.isEmpty else { return [] }
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    var ranges: [Range<String.Index>] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      ranges.append(range)
      return true
    }
    // A transcript the tokenizer finds no sentences in is still a transcript:
    // treat the whole thing as one, and let the word-boundary path cut it.
    return ranges.isEmpty ? [text.startIndex..<text.endIndex] : ranges
  }

  /// Cuts one over-long sentence into ceiling-sized pieces at word boundaries.
  ///
  /// Slices the ORIGINAL text between the first and last word of each piece, so
  /// the pieces stay verbatim rather than becoming a space-joined rebuild.
  private static func splitAtWordBoundaries(_ sentence: Substring) -> [String] {
    var pieces: [String] = []
    var wordRanges: [Range<Substring.Index>] = []

    var index = sentence.startIndex
    while index < sentence.endIndex {
      while index < sentence.endIndex, sentence[index].isWhitespace {
        index = sentence.index(after: index)
      }
      guard index < sentence.endIndex else { break }
      let start = index
      while index < sentence.endIndex, !sentence[index].isWhitespace {
        index = sentence.index(after: index)
      }
      wordRanges.append(start..<index)
    }

    var cursor = 0
    while cursor < wordRanges.count {
      let end = min(cursor + maximumWordsPerPart, wordRanges.count)
      let lower = wordRanges[cursor].lowerBound
      let upper = wordRanges[end - 1].upperBound
      pieces.append(String(sentence[lower..<upper]))
      cursor = end
    }
    return pieces
  }

  /// How many words a piece of text contains.
  ///
  /// Whitespace-separated runs, which is the same thing the ceiling was measured
  /// against. Deliberately NOT `NLTokenizer(unit: .word)`: that counts a
  /// hyphenated compound and a contraction as several tokens, so it would report
  /// a different number from the one the 500 was measured with, and the ceiling
  /// would quietly mean something else.
  public static func wordCount(in text: some StringProtocol) -> Int {
    var count = 0
    var inWord = false
    for character in text {
      if character.isWhitespace {
        inWord = false
      } else if !inWord {
        inWord = true
        count += 1
      }
    }
    return count
  }
}
