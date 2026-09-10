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
/// **Two ceilings, because one of them cannot bound every language.** Words for
/// scripts that use spaces, UTF-8 bytes for the ones that do not. See
/// `maximumBytesPerPart`.
///
/// **A part is a verbatim slice of the input.** The splitter never rewrites,
/// normalises or re-spaces anything: whatever the engine produced is what the
/// cleanup chain sees. `TranscriptSplitterTests` asserts the round trip: the
/// non-whitespace characters of the parts, in order, are the non-whitespace
/// characters of the input, with nothing duplicated and nothing dropped.
public enum TranscriptSplitter {

  /// The ceiling every non-empty part obeys. Raising it narrows the promise
  /// above, and the measurement that set it is named there rather than here so
  /// there is one place to re-read before changing it.
  public static let maximumWordsPerPart = 500

  /// The ceiling that binds for a language WITHOUT spaces, in UTF-8 bytes.
  ///
  /// **A word ceiling cannot bound Japanese, Chinese or Thai**, because those
  /// scripts do not put spaces between words: an entire recording counts as one
  /// or two "words" and sails past `maximumWordsPerPart` untouched. Measured on
  /// 600 repeated Japanese sentences, the whitespace-only splitter produced a
  /// single 10,500-character part — about 31,000 UTF-8 bytes, far past the
  /// context preflight in `LLMPolishStep`, which counts BYTES — so the whole
  /// recording came back unpolished. Found by Codex.
  ///
  /// **DERIVED from the preflight, not chosen.** `localPolishTranscriptCeiling`
  /// is the same formula the preflight applies, at EG-1's shipped 16,384-token
  /// window (`eg1-manifest.json`): `(window - promptOverhead) / 2`. It is the
  /// ASCII worst case, so it is conservative for every other script, which is
  /// the safe direction. Reading the authority rather than restating a number
  /// means a window change moves this with it.
  ///
  /// It does NOT bind for English at the word ceiling: 500 words is about 3,900
  /// bytes and this is 7,424, so ordinary prose is still cut where the measured
  /// word ceiling says. Only an unsegmented script reaches it.
  ///
  /// Known limit, stated rather than hidden: S1-mini ships an 8,192-token
  /// window, where the same formula gives 3,328 bytes. A 500-word English part
  /// is already over that and its preflight already refuses one today, before
  /// this splitter existed. Bounding to the smaller window would cut every
  /// English part in half for the polisher most users do not run, so the ceiling
  /// follows EG-1 and the S1-mini gap stays a separate question.
  public static let maximumBytesPerPart = LLMPolishStep.localPolishTranscriptCeiling(
    contextTokens: 16_384)

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

    var pendingBytes = 0

    for range in sentences {
      let sentence = transcript[range]
      let words = wordCount(in: sentence)
      guard words > 0 else { continue }
      let bytes = sentence.utf8.count

      if words > maximumWordsPerPart || bytes > maximumBytesPerPart {
        // A single sentence over a ceiling. Everything already packed goes
        // first, so the run-on's own cuts do not swallow the sentences before
        // it, and the run-on is then cut as small as it has to be.
        flushPending()
        pendingBytes = 0
        parts.append(contentsOf: splitOverlongSentence(sentence))
        continue
      }

      if pendingWords + words > maximumWordsPerPart
        || pendingBytes + bytes > maximumBytesPerPart
      {
        flushPending()
        pendingBytes = 0
      }
      pending.append(sentence)
      pendingWords += words
      pendingBytes += bytes
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

  /// Cuts one over-long sentence into pieces that obey BOTH ceilings.
  ///
  /// Word boundaries first, because a cut between words is the least damaging
  /// one available. Where a single space-free run is still over the byte ceiling
  /// — which is every sentence in a language that does not use spaces — the run
  /// itself is cut at character boundaries, never mid-character.
  ///
  /// Slices the ORIGINAL text between the first and last word of each piece, so
  /// the pieces stay verbatim rather than becoming a space-joined rebuild.
  private static func splitOverlongSentence(_ sentence: Substring) -> [String] {
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
      // Take as many whole words as both ceilings allow, never fewer than one.
      var end = cursor
      var bytes = 0
      while end < wordRanges.count, end - cursor < maximumWordsPerPart {
        let next = sentence[wordRanges[end]].utf8.count + (end > cursor ? 1 : 0)
        if end > cursor, bytes + next > maximumBytesPerPart { break }
        bytes += next
        end += 1
      }
      let lower = wordRanges[cursor].lowerBound
      let upper = wordRanges[end - 1].upperBound
      let piece = sentence[lower..<upper]
      // One word can still be over on its own, which is the unsegmented-script
      // case: cut it by characters.
      if piece.utf8.count > maximumBytesPerPart {
        pieces.append(contentsOf: splitAtCharacterBoundaries(piece))
      } else {
        pieces.append(String(piece))
      }
      cursor = end
    }
    return pieces
  }

  /// The last resort, for a space-free run longer than the byte ceiling.
  ///
  /// Cuts between CHARACTERS, so a multi-byte character is never split in half
  /// and no part is ever mojibake. A part may come in slightly under the ceiling
  /// because the character that would have crossed it is carried to the next
  /// one, which is the safe direction.
  private static func splitAtCharacterBoundaries(_ run: Substring) -> [String] {
    var pieces: [String] = []
    var current = ""
    var bytes = 0
    for character in run {
      let size = String(character).utf8.count
      if bytes + size > maximumBytesPerPart, !current.isEmpty {
        pieces.append(current)
        current = ""
        bytes = 0
      }
      current.append(character)
      bytes += size
    }
    if !current.isEmpty { pieces.append(current) }
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
