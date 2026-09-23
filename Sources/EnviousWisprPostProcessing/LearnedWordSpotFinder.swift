import Foundation

/// Finds possible spoken forms of listed words. It never changes the transcript.
public struct LearnedWordSpotFinder: Sendable {
  public struct PreparedWord: Sendable {
    public let original: String
    public let soundKey: String
    public let lettersOnlyLowercase: String
    public let tokenSet: Set<String>

    fileprivate let wordCount: Int
  }

  public struct Spot: Sendable, Equatable {
    public let text: String
    public let word: String
    public let range: Range<String.Index>
    public let similarity: Double
  }

  private struct Token {
    let start: Int
    let end: Int
  }

  private struct Candidate {
    let similarity: Double
    let firstToken: Int
    let endToken: Int
    let text: String
    let word: String
    let start: Int
    let end: Int
    let order: Int
  }

  public init() {}

  public static func prepare(_ words: [String]) -> [PreparedWord] {
    words.compactMap { word in
      let soundKey = key(word)
      guard soundKey.isEmpty == false else { return nil }
      return PreparedWord(
        original: word,
        soundKey: soundKey,
        lettersOnlyLowercase: lettersOnly(word),
        tokenSet: wordTokens(word),
        wordCount: splitCount(word))
    }
  }

  public func spots(in text: String, words: [PreparedWord], maxSpots: Int) -> [Spot] {
    guard maxSpots > 0, words.isEmpty == false else { return [] }
    let scalars = Array(text.unicodeScalars)
    var indices = [String.Index]()
    indices.reserveCapacity(scalars.count + 1)
    var index = text.unicodeScalars.startIndex
    indices.append(index)
    while index < text.unicodeScalars.endIndex {
      index = text.unicodeScalars.index(after: index)
      indices.append(index)
    }

    var tokens = [Token]()
    var position = 0
    while position < scalars.count {
      guard Self.isWordScalar(scalars[position]) else {
        position += 1
        continue
      }
      let start = position
      repeat { position += 1 } while position < scalars.count && Self.isWordScalar(scalars[position])
      tokens.append(Token(start: start, end: position))
    }

    var candidates = [Candidate]()
    for first in tokens.indices {
      for count in 1...3 where first + count <= tokens.count {
        let start = tokens[first].start
        var end = tokens[first + count - 1].end
        // Python's rstrip(".") removes only trailing U+002E scalars.
        while end > start && scalars[end - 1].value == 46 { end -= 1 }
        let span = String(text[indices[start]..<indices[end]])
        let soundKey = Self.key(span)
        guard soundKey.unicodeScalars.count >= 3 else { continue }
        let letters = Self.lettersOnly(span)
        let spanTokens = Self.wordTokens(span)
        let spanWordCount = Self.splitCount(span)
        for word in words {
          // Swift String equality is canonically normalized; Python's is scalar-exact.
          if Self.sameScalars(span, word.original) { continue }
          let sameCaseOnly = letters == word.lettersOnlyLowercase && spanWordCount == word.wordCount
          if sameCaseOnly || word.tokenSet.isSubset(of: spanTokens) { continue }
          if count > word.wordCount + 1 { continue }
          let allowedLengthDifference = max(2, word.soundKey.unicodeScalars.count / 2)
          if abs(soundKey.unicodeScalars.count - word.soundKey.unicodeScalars.count) > allowedLengthDifference {
            continue
          }

          let soundTail = String(soundKey.dropFirst())
          let wordTail = String(word.soundKey.dropFirst())
          if letters != word.lettersOnlyLowercase
            && Self.quickRatio(soundKey, word.soundKey) < 0.72
            && Self.quickRatio(soundTail, wordTail) - 0.05 < 0.72
          {
            continue
          }
          let similarity = letters == word.lettersOnlyLowercase
            ? 1.0
            : max(Self.ratio(soundKey, word.soundKey), Self.ratio(soundTail, wordTail) - 0.05)
          if similarity >= 0.72 {
            candidates.append(Candidate(
              similarity: similarity, firstToken: first, endToken: first + count,
              text: span, word: word.original, start: start, end: end, order: candidates.count))
          }
        }
      }
    }

    // Python's stable sort keeps generation order for equal similarity and span length.
    candidates.sort {
      if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
      let leftLength = $0.endToken - $0.firstToken
      let rightLength = $1.endToken - $1.firstToken
      return leftLength == rightLength ? $0.order < $1.order : leftLength < rightLength
    }
    // Python dict keys compare code points. Data keeps canonically equivalent
    // Swift strings distinct when they were distinct listed words.
    var taken: [Data: [Range<Int>]] = [:]
    var chosen = [Candidate]()
    for candidate in candidates {
      let span = candidate.firstToken..<candidate.endToken
      let wordIdentity = Data(candidate.word.utf8)
      let prior = taken[wordIdentity, default: []]
      let allowed = prior.allSatisfy { other in
        span.upperBound <= other.lowerBound || other.upperBound <= span.lowerBound
          || (span.lowerBound >= other.lowerBound && span.upperBound <= other.upperBound)
          || (other.lowerBound >= span.lowerBound && other.upperBound <= span.upperBound)
      }
      if allowed {
        taken[wordIdentity, default: []].append(span)
        chosen.append(candidate)
      }
    }
    chosen.sort {
      if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
      let leftLength = $0.endToken - $0.firstToken
      let rightLength = $1.endToken - $1.firstToken
      return leftLength == rightLength ? $0.order < $1.order : leftLength < rightLength
    }
    chosen = Array(chosen.prefix(maxSpots))
    // The final Python sort is stable: equal starts retain their similarity ranking.
    chosen = chosen.enumerated().sorted {
      $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
    }.map(\.element)
    return chosen.map {
      Spot(text: $0.text, word: $0.word,
           range: indices[$0.start]..<indices[$0.end], similarity: $0.similarity)
    }
  }

  /// Equivalent to Python's re.sub(r"[^a-z]", "", s.lower()).
  private static func lettersOnly(_ value: String) -> String {
    String(value.lowercased().unicodeScalars.filter { (97...122).contains($0.value) })
  }

  private static func key(_ value: String) -> String {
    var sound = lettersOnly(value)
    for (from, to) in [
      ("ph", "f"), ("ck", "k"), ("qu", "kw"), ("q", "k"), ("x", "ks"), ("z", "s"),
      ("wh", "w"), ("gh", "g"), ("ch", "c"), ("sh", "s"), ("th", "t"), ("c", "k"), ("y", "i")
    ] {
      sound = sound.replacingOccurrences(of: from, with: to)
    }
    var deduplicated = [Character]()
    for letter in sound where deduplicated.last != letter { deduplicated.append(letter) }
    guard let head = deduplicated.first else { return "" }
    var result = String(head)
    var previousWasVowel = false
    for letter in deduplicated.dropFirst() {
      let isVowel = "aeiou".contains(letter)
      if isVowel {
        if previousWasVowel == false { result.append("a") }
      } else {
        result.append(letter)
      }
      previousWasVowel = isVowel
    }
    return result
  }

  /// Also used to bound exact observed spellings in `LearnedWordCandidates`.
  static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
    (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
      || (48...57).contains(scalar.value) || scalar.value == 39
      || scalar.value == 0x2019 || scalar.value == 46 || scalar.value == 45
  }

  /// Equivalent to re.findall(r"[a-z0-9']+", s.lower()).
  private static func wordTokens(_ value: String) -> Set<String> {
    var result = Set<String>()
    var current = String()
    for scalar in value.lowercased().unicodeScalars {
      if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) || scalar.value == 39 {
        current.unicodeScalars.append(scalar)
      } else if current.isEmpty == false {
        result.insert(current)
        current = ""
      }
    }
    if current.isEmpty == false { result.insert(current) }
    return result
  }

  private static func splitCount(_ value: String) -> Int {
    var count = 0
    var inWord = false
    for scalar in value.unicodeScalars {
      let whitespace = isPythonWhitespace(scalar.value)
      if whitespace == false && inWord == false { count += 1 }
      inWord = whitespace == false
    }
    return count
  }

  private static func isPythonWhitespace(_ value: UInt32) -> Bool {
    (9...13).contains(value) || (28...32).contains(value) || value == 133
      || value == 160 || value == 5760 || (8192...8202).contains(value)
      || value == 8232 || value == 8233 || value == 8239 || value == 8287 || value == 12288
  }

  private static func sameScalars(_ left: String, _ right: String) -> Bool {
    left.unicodeScalars.elementsEqual(right.unicodeScalars)
  }

  /// Character multiset overlap is difflib's quick_ratio upper bound.
  private static func quickRatio(_ a: String, _ b: String) -> Double {
    let a = Array(a.unicodeScalars)
    let b = Array(b.unicodeScalars)
    if a.isEmpty && b.isEmpty { return 1 }
    var counts: [Unicode.Scalar: Int] = [:]
    for scalar in b { counts[scalar, default: 0] += 1 }
    var matches = 0
    for scalar in a where counts[scalar, default: 0] > 0 {
      matches += 1
      counts[scalar, default: 0] -= 1
    }
    return Double(2 * matches) / Double(a.count + b.count)
  }

  /// difflib.SequenceMatcher.ratio(), including the earliest-i/earliest-j tie break.
  /// No elements are junk. Python's autojunk starts at len(b) >= 200; these sound keys are shorter.
  static func ratio(_ a: String, _ b: String) -> Double {
    let a = Array(a.unicodeScalars)
    let b = Array(b.unicodeScalars)
    if a.isEmpty && b.isEmpty { return 1 }
    var positions: [Unicode.Scalar: [Int]] = [:]
    for (j, scalar) in b.enumerated() { positions[scalar, default: []].append(j) }

    func matchedCount(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Int {
      var bestI = aStart
      var bestJ = bStart
      var bestSize = 0
      var previous: [Int: Int] = [:]
      for i in aStart..<aEnd {
        var current: [Int: Int] = [:]
        for j in positions[a[i], default: []] where j >= bStart && j < bEnd {
          let size = previous[j - 1, default: 0] + 1
          current[j] = size
          if size > bestSize {
            bestI = i - size + 1
            bestJ = j - size + 1
            bestSize = size
          }
        }
        previous = current
      }
      if bestSize == 0 { return 0 }
      return bestSize
        + matchedCount(aStart, bestI, bStart, bestJ)
        + matchedCount(bestI + bestSize, aEnd, bestJ + bestSize, bEnd)
    }

    let matches = matchedCount(0, a.count, 0, b.count)
    return Double(2 * matches) / Double(a.count + b.count)
  }
}
