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
  /// #3518: spellings searched per learned phrase, the phrase as taught first.
  private static let maxVariantsPerAlias = 32
  /// #3518: a learned phrase longer than this is searched only as taught (Judge 1 learns 1 to 4
  /// words per side; this bounds the boundary-pair lookups).
  private static let maxExpandedAliasScalars = 120

  private struct Candidate {
    let range: Range<String.Index>
    let word: String
    var composed: Bool
  }

  /// One spelling searched for a learned phrase: the phrase as taught, or (#3518) the phrase
  /// with a learned word inside it written as one of that word's own misspellings.
  /// `retained` holds the unicode-scalar offsets of the learned words left as written: the
  /// only places a spelling the user already has may sit inside a match.
  struct Variant {
    let text: String
    let retained: [Range<Int>]
    let composed: Bool
  }

  /// The questions plus the counts the step logs (#3518).
  package struct Search: Sendable {
    package let questions: [LearnedWordCheckQuestion]
    /// Questions whose spot matched a spelling the expansion built, not a phrase as taught.
    package let composed: Int
    /// Eligible candidates collected but cut by `maxSpots`. Not a count of every spot left
    /// unsearched: per-spelling scanning limits and the 32-spelling cap are not counted.
    package let truncated: Int
  }

  private struct CandidateKey: Hashable {
    let range: Range<String.Index>
    let wordUTF8: Data
  }

  public static func learnedWords(from vocabulary: [CustomWord]) -> [LearnedWord] {
    vocabulary.compactMap { entry in
      guard entry.source != .pack, entry.hasCheckerAliases else { return nil }
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
    search(for: text, learned: learned, maxSpots: maxSpots, knownSpellings: knownSpellings)
      .questions
  }

  /// `questions(for:learned:maxSpots:knownSpellings:)` with the counts the step logs.
  ///
  /// #3518 founder rule (2026-10-07): when a learned phrase contains another learned word,
  /// that word's own misspellings count there too. Judge 1 learns from the text on screen,
  /// which this check may already have changed ("Sarab" -> "Saurabh"), so the user's fix
  /// "Saurabh A V" -> "Saurabhav" is saved in a spelling the recogniser never writes; it
  /// writes "Sarab A V". Every spelling built this way is still only a question.
  package static func search(
    for text: String, learned: [LearnedWord], maxSpots: Int = 16,
    knownSpellings: [String] = []
  ) -> Search {
    guard text.isEmpty == false, learned.isEmpty == false else {
      return Search(questions: [], composed: 0, truncated: 0)
    }
    var candidates = [Candidate]()
    var seen = [CandidateKey: Int]()
    // #3105 founder live test: "EnviousWispr" (already right, from the user's own word)
    // was asked about and swapped for the learned "EnviousSales". Text already spelled
    // exactly as one of the user's words is final: no spot overlapping it is asked.
    let settled = settledRanges(in: text, knownSpellings: knownSpellings)

    // One budget for every question the checker is asked (Codex PR-3 review: a
    // common alias repeated through a long dictation must not turn into hundreds
    // of questions). The budget keeps the EARLIEST spots in the text, whichever
    // entry they belong to: each alias contributes at most `maxSpots` matches,
    // enough to cover its share of the first `maxSpots`, and the cut is made
    // after sorting.
    // #3518: a settled spelling inside a longer match is final unless it is a learned word
    // the phrase itself contains, left as written. Text the expansion substituted earns no
    // exemption, and a spelling equal to the whole match or only partly inside it never does.
    func add(_ range: Range<String.Index>, word: String, variant: Variant) -> Bool {
      let retained = retainedRanges(of: variant, matchedAt: range, in: text)
      guard
        settled.allSatisfy({ !$0.overlaps(range) || ($0 != range && retained.contains($0)) })
      else { return false }
      guard text[range].unicodeScalars.elementsEqual(word.unicodeScalars) == false else {
        return false
      }
      let key = CandidateKey(range: range, wordUTF8: Data(word.utf8))
      if let existing = seen[key] {
        // The same spot reached as taught and as built counts as taught, whichever came
        // first (second-pass review: the count followed alias order).
        if variant.composed == false { candidates[existing].composed = false }
        return false
      }
      seen[key] = candidates.count
      candidates.append(Candidate(range: range, word: word, composed: variant.composed))
      return true
    }

    let misspellings = misspellingsByWord(learned)
    for entry in learned {
      for observed in entry.observedMisspellings where observed.isEmpty == false {
        for variant in variants(of: observed, owner: entry.canonical, misspellings: misspellings) {
          var searchStart = text.startIndex
          var added = 0
          while added < maxSpots, searchStart < text.endIndex,
            let range = text.range(
              of: variant.text, options: .caseInsensitive, range: searchStart..<text.endIndex)
          {
            let matched = text[range]
            let sameLettersIgnoringCase = matched.lowercased().unicodeScalars.elementsEqual(
              variant.text.lowercased().unicodeScalars)
            if sameLettersIgnoringCase && isWholeWord(range, in: text),
              add(range, word: entry.canonical, variant: variant)
            {
              added += 1
            }
            searchStart = text.unicodeScalars.index(after: range.lowerBound)
          }
        }
      }
    }

    // #3518: at one start, the word with the longest fix is asked first, so the budget never
    // keeps a shorter fix for another word in place of it ("Sarab A V" -> "Saurabhav" before
    // "Sarab" -> "Saurabh"). Within one word the shorter span still comes first, as the applier
    // keeps it (#3105; Codex diff review r4: a same-word phrase must not displace it at the
    // budget). One key per candidate, so the order is total.
    struct StartWord: Hashable {
      let start: String.Index
      let word: String
    }
    var longestForWord = [StartWord: String.Index]()
    for candidate in candidates {
      let key = StartWord(start: candidate.range.lowerBound, word: candidate.word)
      longestForWord[key] = max(longestForWord[key] ?? candidate.range.upperBound, candidate.range.upperBound)
    }
    candidates.sort {
      if $0.range.lowerBound != $1.range.lowerBound {
        return $0.range.lowerBound < $1.range.lowerBound
      }
      let left = longestForWord[StartWord(start: $0.range.lowerBound, word: $0.word)]!
      let right = longestForWord[StartWord(start: $1.range.lowerBound, word: $1.word)]!
      if left != right { return left > right }
      if $0.word != $1.word { return $0.word < $1.word }
      return $0.range.upperBound < $1.range.upperBound
    }
    let kept = candidates.prefix(max(0, maxSpots))
    return Search(
      questions: kept.enumerated().map { id, candidate in
        LearnedWordCheckQuestion(
          id: id, sentence: text, range: candidate.range,
          contextRange: contextRange(in: text, around: candidate.range), word: candidate.word)
      },
      composed: kept.filter(\.composed).count,
      truncated: candidates.count - kept.count)
  }

  /// Every learned word's misspellings by lowercased canonical. Entries spelled alike are
  /// merged, and each list is deduplicated and sorted by UTF-8 bytes, so the spellings built
  /// from them do not depend on vocabulary order.
  private static func misspellingsByWord(_ learned: [LearnedWord]) -> [String: [String]] {
    var merged = [String: Set<String>]()
    for entry in learned {
      merged[entry.canonical.lowercased(), default: []].formUnion(
        entry.observedMisspellings.filter { $0.isEmpty == false })
    }
    return merged.mapValues { $0.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } }
  }

  /// The spellings searched for one learned phrase, the phrase as taught first, at most
  /// `maxVariantsPerAlias` of them. A phrase is expanded only where ANOTHER learned word sits
  /// strictly inside it as a whole word, found in the phrase as taught ("Saurabh/team" counts:
  /// no space is needed). A phrase is not expanded through the word it is taught for
  /// ("Saurabh A V" -> "Saurabh"): two fixes to one word keep the shorter span (#3105), so that
  /// question could never win, and the winner would follow the question budget.
  /// Overlapping learned words ("Envious" and "Envious Labs") are alternatives: one
  /// spelling never replaces both.
  static func variants(
    of alias: String, owner: String, misspellings: [String: [String]]
  ) -> [Variant] {
    struct Occurrence {
      let range: Range<Int>
      let key: String
    }
    let scalars = Array(alias.unicodeScalars)
    // Every stretch of the phrase that starts and ends on a word boundary, by the same rule
    // the matcher and the settled check use (`isWholeWord`), looked up as a learned word: one
    // dictionary lookup per stretch, so a large vocabulary costs no more here, and every
    // learned word the matcher would see inside the phrase is found ("Saurabh" in
    // "Saurabh/team", both "C" and "C++" in "C++ A V"). Overlaps are kept; variant
    // building never replaces two overlapping words at once. A learned phrase is 1 to 4
    // words (Judge 1), so the stretches are few; a long one is not expanded.
    guard scalars.count <= maxExpandedAliasScalars else {
      return [Variant(text: alias, retained: [], composed: false)]
    }
    let ownerKey = owner.lowercased()
    let starts = scalars.indices.filter {
      scalars[$0].properties.isWhitespace == false
        && ($0 == 0 || isWordScalar(scalars[$0 - 1]) == false)
    }
    let ends = (1...scalars.count).filter { end in
      scalars[end - 1].properties.isWhitespace == false
        && (end == scalars.count || isWordScalar(scalars[end]) == false
          || isSentencePeriod(in: alias, at: alias.unicodeScalars.index(
            alias.unicodeScalars.startIndex, offsetBy: end)))
    }
    // Only a word INSIDE the phrase: a phrase that is itself another learned word (#3105's
    // "Envious Labs" taught as a misspelling of "EnviousSales") is never rebuilt from that
    // word's misspellings.
    var occurrences = [Occurrence]()
    for start in starts {
      for end in ends where end > start && (start > 0 || end < scalars.count) {
        let key = String(String.UnicodeScalarView(scalars[start..<end])).lowercased()
        if key != ownerKey, misspellings[key] != nil {
          occurrences.append(Occurrence(range: start..<end, key: key))
        }
      }
    }
    guard occurrences.isEmpty == false else {
      return [Variant(text: alias, retained: [], composed: false)]
    }
    occurrences.sort {
      if $0.range.lowerBound != $1.range.lowerBound {
        return $0.range.lowerBound < $1.range.lowerBound
      }
      if $0.range.count != $1.range.count { return $0.range.count > $1.range.count }
      return $0.key < $1.key
    }

    func build(_ replaced: [(occurrence: Int, with: String)]) -> Variant {
      var text = String.UnicodeScalarView()
      var retained = [Range<Int>]()
      var cursor = 0
      let replacedRanges = replaced.map { occurrences[$0.occurrence].range }
      for occurrence in occurrences
      where replacedRanges.contains(where: { $0.overlaps(occurrence.range) }) == false {
        // A kept learned word: its place in the built spelling, after earlier replacements.
        let shift = replaced.reduce(0) { total, item in
          let range = occurrences[item.occurrence].range
          guard range.upperBound <= occurrence.range.lowerBound else { return total }
          return total + item.with.unicodeScalars.count - range.count
        }
        retained.append(
          (occurrence.range.lowerBound + shift)..<(occurrence.range.upperBound + shift))
      }
      for item in replaced.sorted(by: {
        occurrences[$0.occurrence].range.lowerBound < occurrences[$1.occurrence].range.lowerBound
      }) {
        let range = occurrences[item.occurrence].range
        text.append(contentsOf: scalars[cursor..<range.lowerBound])
        text.append(contentsOf: item.with.unicodeScalars)
        cursor = range.upperBound
      }
      text.append(contentsOf: scalars[cursor...])
      return Variant(text: String(text), retained: retained, composed: replaced.isEmpty == false)
    }

    // The cap counts spellings built, including one spelling reached two ways (each keeps its
    // own exemptions), so a phrase of many overlapping learned words stays bounded (Codex
    // diff review r1: "ha ha" learned from "ha", in a phrase of 28 "ha", took 2.85 s).
    var result = [Variant]()
    func visit(_ index: Int, _ replaced: [(occurrence: Int, with: String)]) {
      guard result.count < maxVariantsPerAlias else { return }
      guard index < occurrences.count else {
        result.append(build(replaced))
        return
      }
      visit(index + 1, replaced)
      let occurrence = occurrences[index]
      guard
        replaced.contains(where: { occurrences[$0.occurrence].range.overlaps(occurrence.range) })
          == false
      else { return }
      for spelling in misspellings[occurrence.key] ?? [] {
        visit(index + 1, replaced + [(index, spelling)])
      }
    }
    visit(0, [])
    return result
  }

  /// The text ranges of a variant's kept learned words in one match, or none when the match
  /// is not scalar-for-scalar the variant (a case mapping that changes length).
  private static func retainedRanges(
    of variant: Variant, matchedAt range: Range<String.Index>, in text: String
  ) -> [Range<String.Index>] {
    guard variant.retained.isEmpty == false else { return [] }
    let scalars = text.unicodeScalars
    guard
      scalars.distance(from: range.lowerBound, to: range.upperBound)
        == variant.text.unicodeScalars.count
    else { return [] }
    return variant.retained.map {
      scalars.index(range.lowerBound, offsetBy: $0.lowerBound)
        ..< scalars.index(range.lowerBound, offsetBy: $0.upperBound)
    }
  }

  /// Whole word in `text`: nothing word-like right before or after, or a sentence-ending
  /// period after.
  private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
    let startsAtBoundary =
      range.lowerBound == text.startIndex
      || isWordScalar(
        text.unicodeScalars[text.unicodeScalars.index(before: range.lowerBound)]) == false
    let endsAtBoundary =
      range.upperBound == text.endIndex
      || isWordScalar(text.unicodeScalars[range.upperBound]) == false
      || Self.isSentencePeriod(in: text, at: range.upperBound)
    return startsAtBoundary && endsAtBoundary
  }

  /// Every whole-word, exact-case occurrence in `text` of a spelling the user already has.
  static func settledRanges(in text: String, knownSpellings: [String]) -> [Range<String.Index>] {
    var ranges = [Range<String.Index>]()
    for spelling in Set(knownSpellings) where spelling.isEmpty == false {
      var searchStart = text.startIndex
      while searchStart < text.endIndex,
        let range = text.range(of: spelling, options: .literal, range: searchStart..<text.endIndex)
      {
        if isWholeWord(range, in: text) { ranges.append(range) }
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
