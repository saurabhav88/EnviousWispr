import Foundation
import Testing

@testable import EnviousWisprLLM

/// #2649 contract delta C1. The rule this pins is asymmetric on purpose, and
/// the asymmetry is the whole point: a wrong `validEmpty` BLINDS the detector
/// that diagnosed #2634 (161 empty responses from one user whose polish never
/// worked), while a wrong `unexpectedEmpty` costs one silent fallback the user
/// already gets. So the rows below spend most of their effort proving the
/// classifier does NOT say valid.
@Suite("Empty polish disposition (#2649 C1)", .tags(.driftGuard))
struct LocalPolishEmptyDispositionTests {

  @Test("filler-only input makes an empty answer correct")
  func fillerOnlyIsValid() {
    #expect(LocalPolishEmptyDisposition.classify(input: "um") == .validEmpty)
    #expect(LocalPolishEmptyDisposition.classify(input: "uh, um.") == .validEmpty)
    #expect(LocalPolishEmptyDisposition.classify(input: "Um Uh ERR") == .validEmpty)
    #expect(LocalPolishEmptyDisposition.classify(input: "hmm mm mhm") == .validEmpty)
    #expect(LocalPolishEmptyDisposition.classify(input: "  um   uh  ") == .validEmpty)
  }

  /// The load-bearing direction. Every row here would, if wrongly classified,
  /// hide a real failure from the telemetry that found #2634.
  @Test("real words always make an empty answer a failure")
  func ordinaryWordsAreNeverFiller() {
    for input in [
      "send the report by friday",
      "So it is.",                    // `so` alone is a real sentence
      "like",                          // a real word, not a disfluency
      "you know",                      // two real words
      "um send the report",            // one filler plus real content
      "the",
      "um uh so like you know um",     // the card's own example, and it contains real words
    ] {
      #expect(
        LocalPolishEmptyDisposition.classify(input: input) == .unexpectedEmpty,
        "\(input) must not be treated as filler-only")
    }
  }

  /// Nothing at all is not the same as filler. An engine handed an empty string
  /// had no work to do, and calling that a correct empty would let a broken
  /// upstream stage look healthy.
  @Test("empty or punctuation-only input is a failure, not a valid empty")
  func emptyInputIsNotValidEmpty() {
    for input in ["", "   ", "\n\t", ".", "...", " , . "] {
      #expect(
        LocalPolishEmptyDisposition.classify(input: input) == .unexpectedEmpty,
        "\(input.debugDescription) must not be treated as filler-only")
    }
  }

  /// The filler set must contain no word that can carry meaning. This is a
  /// structural check on the SET rather than on a behaviour, because the way
  /// this rule breaks is somebody adding a plausible-looking entry.
  @Test("the filler set contains no ordinary English word")
  func fillerSetHoldsNoRealWords() {
    for banned in ["like", "so", "well", "you", "know", "right", "okay", "just", "actually"] {
      #expect(
        LocalPolishEmptyDisposition.nonLexicalFillers.contains(banned) == false,
        "\(banned) is an ordinary word; admitting it would blind the empty-response detector")
    }
    #expect(LocalPolishEmptyDisposition.nonLexicalFillers.isEmpty == false)
  }

  /// A hyphenated disfluency must not be silently joined into something else.
  @Test("inner punctuation is preserved, so mm-hmm is not read as mmhmm")
  func innerPunctuationIsNotStripped() {
    // `mm-hmm` is not in the set as written, so it must classify unexpected
    // rather than quietly matching `mmhmm`. Stated as a row because the
    // trimming rule is what makes it true, and a future "tidy up" of that
    // trimming would change the answer with nothing else failing.
    #expect(LocalPolishEmptyDisposition.classify(input: "mm-hmm") == .unexpectedEmpty)
  }
}
