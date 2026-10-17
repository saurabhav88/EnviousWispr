import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// Recognition suggestions, separate from the rules that replace a mishearing (#3457).
package enum ApplePreviewHints {
  /// Apple's contextual-strings limit applies across all tags; we use only general.
  private static let maximumPhrases = 100

  package static func build(from words: [CustomWord]) -> [String] {
    var phrases: [String] = []
    var seen = Set<String>()
    // Storage puts built-ins first. A user's saved AND learned words take precedence.
    for source in [WordSource.user, .builtin] {
      for word in words where word.source == source {
        let tokens = word.canonical.split(whereSeparator: \.isWhitespace)
        guard (1...2).contains(tokens.count) else { continue }
        let phrase = tokens.joined(separator: " ")
        let key = phrase.precomposedStringWithCanonicalMapping.lowercased()
        guard seen.insert(key).inserted else { continue }
        phrases.append(phrase)
        if phrases.count == maximumPhrases { return phrases }
      }
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
