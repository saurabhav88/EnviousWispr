import EnviousWisprCore
import Foundation

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

  /// One question per place a misspelling the user has actually fixed before appears
  /// again (founder 2026-09-25: known aliases only). No sound-alike search: the checker
  /// cannot hear the audio, so a correctly heard word that merely sounds like a learned
  /// word ("Envious Labs" / "EnviousSales") must never be offered to it.
  public static func questions(
    for text: String, learned: [LearnedWord], maxSpots: Int = 16,
    knownSpellings: [String] = []
  ) -> [LearnedWordCheckQuestion] {
    guard text.isEmpty == false, learned.isEmpty == false else { return [] }
    var candidates = [Candidate]()
    var seen = Set<CandidateKey>()
    // #3105 founder live test: "EnviousWispr" (already right, from the user's own word)
    // was asked about and swapped for the learned "EnviousSales". Text already spelled
    // exactly as one of the user's words is final: no spot overlapping it is asked.
    let settled = settledRanges(in: text, knownSpellings: knownSpellings)

    // One budget for every question the checker is asked (Codex PR-3 review: a
    // common alias repeated through a long dictation must not turn into hundreds
    // of questions).
    func add(_ range: Range<String.Index>, word: String) {
      guard candidates.count < maxSpots else { return }
      guard settled.allSatisfy({ !$0.overlaps(range) }) else { return }
      guard text[range].unicodeScalars.elementsEqual(word.unicodeScalars) == false else { return }
      let key = CandidateKey(range: range, wordUTF8: Data(word.utf8))
      if seen.insert(key).inserted { candidates.append(Candidate(range: range, word: word)) }
    }

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
          let startsAtBoundary =
            range.lowerBound == text.startIndex
            || isWordScalar(
              text.unicodeScalars[text.unicodeScalars.index(before: range.lowerBound)]) == false
          let endsAtBoundary =
            range.upperBound == text.endIndex
            || isWordScalar(text.unicodeScalars[range.upperBound]) == false
            || Self.isSentencePeriod(in: text, at: range.upperBound)
          if sameLettersIgnoringCase && startsAtBoundary && endsAtBoundary {
            add(range, word: entry.canonical)
          }
          searchStart = text.unicodeScalars.index(after: range.lowerBound)
        }
      }
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

  /// Every whole-word, exact-case occurrence in `text` of a spelling the user already has.
  static func settledRanges(in text: String, knownSpellings: [String]) -> [Range<String.Index>] {
    var ranges = [Range<String.Index>]()
    for spelling in Set(knownSpellings) where spelling.isEmpty == false {
      var searchStart = text.startIndex
      while searchStart < text.endIndex,
        let range = text.range(of: spelling, options: .literal, range: searchStart..<text.endIndex)
      {
        let startsAtBoundary =
          range.lowerBound == text.startIndex
          || isWordScalar(
            text.unicodeScalars[text.unicodeScalars.index(before: range.lowerBound)]) == false
        let endsAtBoundary =
          range.upperBound == text.endIndex
          || isWordScalar(text.unicodeScalars[range.upperBound]) == false
          || Self.isSentencePeriod(in: text, at: range.upperBound)
        if startsAtBoundary && endsAtBoundary { ranges.append(range) }
        searchStart = text.unicodeScalars.index(after: range.lowerBound)
      }
    }
    return ranges
  }

  /// A letter or digit in any script, an apostrophe, a period or a hyphen: the
  /// characters that continue a word for boundary checks (`U.S.`, `co-op`, `don't`).
  static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    CharacterSet.alphanumerics.contains(scalar)
      || scalar.value == 39 || scalar.value == 0x2019 || scalar.value == 46 || scalar.value == 45
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
        upper =
          scalars[cursor] == "\n" || scalars[cursor] == "\r"
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
    lower =
      text.index(spot.lowerBound, offsetBy: -leftCount, limitedBy: sentence.lowerBound)
      ?? sentence.lowerBound
    upper =
      text.index(spot.upperBound, offsetBy: rightCount, limitedBy: sentence.upperBound)
      ?? sentence.upperBound
    let unsnapped = lower..<upper
    // Include whole edge words when a 200-character cut lands inside them.
    while lower > sentence.lowerBound, lower < spot.lowerBound,
      isWordScalar(scalars[lower]),
      isWordScalar(scalars[scalars.index(before: lower)])
    {
      lower = text.index(before: lower)
    }
    while upper < sentence.upperBound, upper > spot.upperBound,
      isWordScalar(scalars[upper]),
      isWordScalar(scalars[scalars.index(before: upper)])
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
    // The last period of an initialism ("U.S. Army") ends no sentence: an uppercase
    // letter right after another period.
    if index > scalars.startIndex {
      let letter = scalars.index(before: index)
      if letter > scalars.startIndex,
        CharacterSet.uppercaseLetters.contains(scalars[letter]),
        scalars[scalars.index(before: letter)] == "."
      {
        return false
      }
    }
    let next = scalars.index(after: index)
    return next == scalars.endIndex || scalars[next].properties.isWhitespace
  }
}
