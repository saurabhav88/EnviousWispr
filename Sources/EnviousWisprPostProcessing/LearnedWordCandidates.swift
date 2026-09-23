import Foundation
import EnviousWisprCore

public struct LearnedWord: Sendable, Equatable {
  public let canonical: String
  public let observedMisspellings: [String]

  public init(canonical: String, observedMisspellings: [String]) {
    self.canonical = canonical
    self.observedMisspellings = observedMisspellings
  }
}

public enum LearnedWordCandidates: Sendable {
  // Keep each checker prompt near its one-sentence training shape and within shared KV.
  private static let maxContextCharacters = 400
  private static let contextSideCharacters = 200
  private static let maxBoundaryOverhang = 20

  private struct Candidate {
    let range: Range<String.Index>
    let word: String
  }

  private struct CandidateKey: Hashable {
    let range: Range<String.Index>
    let wordUTF8: Data
  }

  public static func learnedWords(from vocabulary: [CustomWord]) -> [LearnedWord] {
    vocabulary.compactMap { entry in
      guard entry.source != .pack, entry.isAutoLearned else { return nil }
      let observed = entry.learnedAt == nil ? entry.learnedAliases : entry.aliases
      return LearnedWord(canonical: entry.canonical, observedMisspellings: observed)
    }
  }

  public static func questions(
    for text: String, learned: [LearnedWord], maxSpots: Int = 16
  ) -> [LearnedWordCheckQuestion] {
    guard text.isEmpty == false, learned.isEmpty == false else { return [] }
    var candidates = [Candidate]()
    var seen = Set<CandidateKey>()

    // One budget for every question the checker is asked, exact observed
    // spellings first (the strongest prior), then sound matches (Codex PR-3
    // review: a common alias repeated through a long dictation must not turn
    // into hundreds of questions).
    func add(_ range: Range<String.Index>, word: String) {
      guard candidates.count < maxSpots else { return }
      guard text[range].unicodeScalars.elementsEqual(word.unicodeScalars) == false else { return }
      let key = CandidateKey(range: range, wordUTF8: Data(word.utf8))
      if seen.insert(key).inserted { candidates.append(Candidate(range: range, word: word)) }
    }

    // An observed spelling is a direct prior even when the sound matcher misses it.
    for entry in learned {
      for observed in entry.observedMisspellings where observed.isEmpty == false {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(
                of: observed, options: .caseInsensitive, range: searchStart..<text.endIndex)
        {
          let matched = text[range]
          let sameLettersIgnoringCase = matched.lowercased().unicodeScalars.elementsEqual(
            observed.lowercased().unicodeScalars)
          let startsAtBoundary = range.lowerBound == text.startIndex
            || LearnedWordSpotFinder.isWordScalar(
              text.unicodeScalars[text.unicodeScalars.index(before: range.lowerBound)]) == false
          let endsAtBoundary = range.upperBound == text.endIndex
            || LearnedWordSpotFinder.isWordScalar(text.unicodeScalars[range.upperBound]) == false
            || Self.isSentencePeriod(in: text, at: range.upperBound)
          if sameLettersIgnoringCase && startsAtBoundary && endsAtBoundary {
            add(range, word: entry.canonical)
          }
          searchStart = text.unicodeScalars.index(after: range.lowerBound)
        }
      }
    }

    // Sound matches fill whatever the exact spellings left of the budget.
    let finder = LearnedWordSpotFinder()
    let words = LearnedWordSpotFinder.prepare(learned.map(\.canonical))
    for spot in finder.spots(in: text, words: words, maxSpots: maxSpots) {
      add(spot.range, word: spot.word)
    }

    candidates.sort {
      if $0.range.lowerBound != $1.range.lowerBound {
        return $0.range.lowerBound < $1.range.lowerBound
      }
      return $0.word < $1.word
    }
    return candidates.enumerated().map { id, candidate in
      LearnedWordCheckQuestion(
        id: id, sentence: text, range: candidate.range,
        contextRange: contextRange(in: text, around: candidate.range), word: candidate.word)
    }
  }

  private static func contextRange(
    in text: String, around spot: Range<String.Index>
  ) -> Range<String.Index> {
    let scalars = text.unicodeScalars
    var lower = text.startIndex
    var cursor = text.startIndex
    while cursor < spot.lowerBound {
      if isSentenceEnd(in: text, at: cursor) {
        lower = scalars.index(after: cursor)
      }
      cursor = scalars.index(after: cursor)
    }

    var upper = text.endIndex
    cursor = spot.upperBound
    while cursor < text.endIndex {
      if isSentenceEnd(in: text, at: cursor) {
        upper = scalars[cursor] == "\n" || scalars[cursor] == "\r"
          ? cursor : scalars.index(after: cursor)
        break
      }
      cursor = scalars.index(after: cursor)
    }
    while lower < spot.lowerBound && scalars[lower].properties.isWhitespace {
      lower = scalars.index(after: lower)
    }
    while upper > spot.upperBound {
      let previous = scalars.index(before: upper)
      guard scalars[previous].properties.isWhitespace else { break }
      upper = previous
    }

    let sentence = lower..<upper
    guard text[sentence].count > maxContextCharacters else { return sentence }
    let available = max(0, maxContextCharacters - text[spot].count)
    let leftCount = min(contextSideCharacters, available / 2)
    let rightCount = min(contextSideCharacters, available - leftCount)
    lower = text.index(spot.lowerBound, offsetBy: -leftCount, limitedBy: sentence.lowerBound)
      ?? sentence.lowerBound
    upper = text.index(spot.upperBound, offsetBy: rightCount, limitedBy: sentence.upperBound)
      ?? sentence.upperBound
    let unsnapped = lower..<upper
    // Include whole edge words when a 200-character cut lands inside them.
    while lower > sentence.lowerBound, lower < spot.lowerBound,
      LearnedWordSpotFinder.isWordScalar(scalars[lower]),
      LearnedWordSpotFinder.isWordScalar(scalars[scalars.index(before: lower)])
    {
      lower = text.index(before: lower)
    }
    while upper < sentence.upperBound, upper > spot.upperBound,
      LearnedWordSpotFinder.isWordScalar(scalars[upper]),
      LearnedWordSpotFinder.isWordScalar(scalars[scalars.index(before: upper)])
    {
      upper = text.index(after: upper)
    }
    // A single overlong token has no nearby word boundary; keep the bounded
    // window rather than sending the full run-on take to the shared KV.
    if text[lower..<upper].count > maxContextCharacters + maxBoundaryOverhang {
      return unsnapped
    }
    return lower..<upper
  }

  private static func isSentenceEnd(in text: String, at index: String.Index) -> Bool {
    let scalars = text.unicodeScalars
    let scalar = scalars[index]
    if scalar == "\n" || scalar == "\r" { return true }
    if scalar == "." { return isSentencePeriod(in: text, at: index) }
    guard scalar == "!" || scalar == "?" || scalar == "…" else { return false }
    let next = scalars.index(after: index)
    return next == scalars.endIndex || scalars[next].properties.isWhitespace
  }

  /// A period that ends a sentence ("... my coffee mug."), not one inside a dotted
  /// term ("mug.io"): followed by the end of the text or by whitespace.
  static func isSentencePeriod(in text: String, at index: String.Index) -> Bool {
    let scalars = text.unicodeScalars
    guard index < scalars.endIndex, scalars[index] == "." else { return false }
    let next = scalars.index(after: index)
    return next == scalars.endIndex || scalars[next].properties.isWhitespace
  }
}
