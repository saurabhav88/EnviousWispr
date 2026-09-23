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
      LearnedWordCheckQuestion(id: id, sentence: text, range: candidate.range, word: candidate.word)
    }
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
