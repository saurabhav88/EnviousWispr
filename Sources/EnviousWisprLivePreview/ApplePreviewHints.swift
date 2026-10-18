import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// Recognition suggestions, separate from the rules that replace a mishearing (#3457).
package enum ApplePreviewHints {
  /// Apple's contextual-strings limit applies across all tags; we use only general.
  private static let maximumPhrases = 100

  package static func build(from words: [CustomWord]) -> [String] {
    var phrases: [String] = []
    phrases.reserveCapacity(maximumPhrases)
    var seen = Set<String>()

    func canonicalPhrase(_ word: CustomWord) -> String? {
      let tokens = word.canonical.split(whereSeparator: \.isWhitespace)
      guard (1...2).contains(tokens.count) else { return nil }
      let phrase = tokens.joined(separator: " ")
      let key = phrase.precomposedStringWithCanonicalMapping.lowercased()
      return seen.insert(key).inserted ? phrase : nil
    }

    // Storage puts built-ins first. A user's saved AND learned words take precedence.
    // #3917: additions append, so retain the newest eligible user phrases on overflow.
    // This is addition order, not usage frequency. Keep every seen key, including an
    // evicted phrase's key: a later duplicate must not promote an existing spelling.
    var oldest = 0
    for word in words where word.source == .user {
      guard let phrase = canonicalPhrase(word) else { continue }
      if phrases.count < maximumPhrases {
        phrases.append(phrase)
      } else {
        phrases[oldest] = phrase
        oldest = (oldest + 1) % maximumPhrases
      }
    }
    if oldest != 0 {
      phrases = Array(phrases[oldest...] + phrases[..<oldest])
    }

    // Libraries that fit keep their exact order and the same built-in filling.
    guard phrases.count < maximumPhrases else { return phrases }
    for word in words where word.source == .builtin {
      guard let phrase = canonicalPhrase(word) else { continue }
      phrases.append(phrase)
      if phrases.count == maximumPhrases { break }
    }
    return phrases
  }

  struct Inputs: Sendable {
    let lookups: WordCorrector.Lookups?
    let phrases: [String]
  }

  /// Apple alone follows this application flag. Universal keeps its original lookups.
  static func inputs(for vocabulary: LivePreviewVocabulary) -> Inputs {
    Inputs(
      lookups: vocabulary.dictionaryEnabled ? vocabulary.lookups : nil,
      phrases: vocabulary.dictionaryEnabled ? vocabulary.contextualPhrases : [])
  }
}
