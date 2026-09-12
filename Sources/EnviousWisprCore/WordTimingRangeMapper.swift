import Foundation

/// Binds an engine's timed words onto positions in `ASRResult.text` (#2809).
///
/// Neither ASR engine gives a character offset into `text` alongside a word's time — only a
/// word string and a start/end. This maps ONLY the correspondence that every valid
/// order-preserving alignment between the engine's words and `text`'s own words would agree
/// on: a text word that could equally be either of two identical engine words (or vice versa)
/// stays untimed rather than guessed. `text` itself is never touched.
public enum WordTimingRangeMapper {

  /// Above this many candidate (engine word × text word) pairs, the exact forced-alignment
  /// search is skipped in favor of returning no bound words for the mismatched region: real
  /// divergence between an engine's words and its own `text` is not expected at this pin (no
  /// CTC rescoring is wired in `EnviousWisprASR`), so this only ever bounds the cost of an
  /// unexpected future mismatch on a very long file, never the common case below.
  static let forcedAlignmentSearchCap = 4_000_000

  /// One text run with its UTF-16 range in the source `text`.
  struct TextWord {
    let range: Range<Int>
    let text: Substring
  }

  public static func map(
    text: String,
    audioDurationMs: Int,
    words: [(word: String, startMs: Int?, endMs: Int?)]
  ) -> (words: [ASRWordTiming], coverage: ASRWordTimingCoverage) {
    let textWords = tokenize(text)
    let total = textWords.reduce(0) { $0 + ($1.range.upperBound - $1.range.lowerBound) }

    guard !textWords.isEmpty else {
      return ([], ASRWordTimingCoverage(timed: 0, total: 0))
    }
    guard !words.isEmpty else {
      let untimed = textWords.map {
        ASRWordTiming(word: String($0.text), range: $0.range, startMs: nil, endMs: nil)
      }
      return (untimed, ASRWordTimingCoverage(timed: 0, total: total))
    }

    let engineWords = words.map { $0.word.trimmingCharacters(in: .whitespaces) }
    let boundTextIndex = forcedBinding(engineWords: engineWords, textWords: textWords.map(\.text))

    var result: [ASRWordTiming] = []
    result.reserveCapacity(textWords.count)
    var timed = 0
    for (j, textWord) in textWords.enumerated() {
      let length = textWord.range.upperBound - textWord.range.lowerBound
      guard let i = boundTextIndex[j] else {
        result.append(
          ASRWordTiming(
            word: String(textWord.text), range: textWord.range, startMs: nil, endMs: nil))
        continue
      }
      let engineWord = words[i]
      if let startMs = engineWord.startMs, let endMs = engineWord.endMs,
        startMs >= 0, endMs >= startMs, endMs <= audioDurationMs
      {
        result.append(
          ASRWordTiming(
            word: String(textWord.text), range: textWord.range, startMs: startMs, endMs: endMs))
        timed += length
      } else {
        result.append(
          ASRWordTiming(
            word: String(textWord.text), range: textWord.range, startMs: nil, endMs: nil))
      }
    }
    return (result, ASRWordTimingCoverage(timed: timed, total: total))
  }

  // MARK: - Text tokenization

  /// Whitespace-separated runs with their UTF-16 ranges. Grapheme-cluster aware (walks
  /// `Character`s, not UTF-16 units directly), so a run never splits a multi-scalar cluster.
  static func tokenize(_ text: String) -> [TextWord] {
    var tokens: [TextWord] = []
    var i = text.startIndex
    while i < text.endIndex {
      if text[i].isWhitespace {
        i = text.index(after: i)
        continue
      }
      var j = i
      while j < text.endIndex, !text[j].isWhitespace {
        j = text.index(after: j)
      }
      let lower = i.utf16Offset(in: text)
      let upper = j.utf16Offset(in: text)
      tokens.append(TextWord(range: lower..<upper, text: text[i..<j]))
      i = j
    }
    return tokens
  }

  // MARK: - Forced alignment

  /// Index into `engineWords` for each `textWords` position that every maximum
  /// order-preserving alignment (matching equal strings, indices increasing on both sides)
  /// agrees on. A position absent from the result has no forced correspondence: either no
  /// engine word matches it in order, or more than one alignment of maximum length would bind
  /// it differently.
  static func forcedBinding(engineWords: [String], textWords: [Substring]) -> [Int: Int] {
    let m = engineWords.count
    let n = textWords.count

    // Fast path: identical sequences, position for position. When both sides have the same
    // length and match everywhere, an order-preserving bijection over two equal-size index
    // sets has exactly one shape (the identity) — nothing to disambiguate, whatever repeats
    // either sequence contains.
    if m == n {
      var identity = true
      for k in 0..<m where engineWords[k] != textWords[k] {
        identity = false
        break
      }
      if identity {
        var bound: [Int: Int] = [:]
        bound.reserveCapacity(n)
        for k in 0..<n { bound[k] = k }
        return bound
      }
    }

    guard m > 0, n > 0, m * n <= forcedAlignmentSearchCap else { return [:] }

    // Forward table: L[i][j] = LCS length of engineWords[0..<i], textWords[0..<j].
    let cols = n + 1
    var forward = [Int](repeating: 0, count: (m + 1) * cols)
    for i in 1...m {
      let row = i * cols
      let prevRow = (i - 1) * cols
      for j in 1...n {
        if engineWords[i - 1] == textWords[j - 1] {
          forward[row + j] = forward[prevRow + (j - 1)] + 1
        } else {
          forward[row + j] = max(forward[prevRow + j], forward[row + (j - 1)])
        }
      }
    }
    let total = forward[m * cols + n]
    guard total > 0 else { return [:] }

    // Backward table: R[i][j] = LCS length of engineWords[i..<m], textWords[j..<n].
    var backward = [Int](repeating: 0, count: (m + 1) * cols)
    for i in stride(from: m - 1, through: 0, by: -1) {
      let row = i * cols
      let nextRow = (i + 1) * cols
      for j in stride(from: n - 1, through: 0, by: -1) {
        if engineWords[i] == textWords[j] {
          backward[row + j] = backward[nextRow + (j + 1)] + 1
        } else {
          backward[row + j] = max(backward[nextRow + j], backward[row + (j + 1)])
        }
      }
    }

    // Every (i, j) with engineWords[i] == textWords[j] that lies on some maximum alignment,
    // grouped by the rank (1-based position in the LCS) it would occupy there. A rank with
    // exactly one candidate is forced in every maximum alignment; a rank with more than one
    // is ambiguous and none of its candidates are bound.
    var candidatesByRank: [Int: [(i: Int, j: Int)]] = [:]
    for i in 0..<m {
      let fRow = i * cols
      let bRow = (i + 1) * cols
      for j in 0..<n where engineWords[i] == textWords[j] {
        let rank = forward[fRow + j] + 1
        guard rank + backward[bRow + (j + 1)] == total else { continue }
        candidatesByRank[rank, default: []].append((i, j))
      }
    }

    var bound: [Int: Int] = [:]
    for (_, candidates) in candidatesByRank where candidates.count == 1 {
      let pair = candidates[0]
      bound[pair.j] = pair.i
    }
    return bound
  }
}
