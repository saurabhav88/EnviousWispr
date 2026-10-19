import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #3893: word correction joins or replaces several words only when nothing but spaces
/// separates them, and Pass 0 never joins through an ordinary small word.
///
/// **Product Outcome.** When this fails, the user sees a full stop or comma deleted and two
/// sentences glued into a saved word, or "just in case" turned into a contact's name.
@Suite(.tags(.productOutcome))
struct WordCorrectorBoundaryTests {
  private let corrector = WordCorrector()

  private func corrected(_ input: String, _ words: [CustomWord]) -> String {
    corrector.correct(input, against: words).0
  }

  @Test("a saved word is not joined across a full stop, comma or dash")
  func joinsStopAtPunctuation() {
    let words = [CustomWord(canonical: "EnviousWispr", aliases: ["envious wispr"])]
    for sentence in ["I felt envious. Wispr helped", "so envious, wispr", "envious - wispr"] {
      #expect(corrected(sentence, words) == sentence, "\(sentence)")
    }
    #expect(corrected("Envious Wispr is open", words) == "EnviousWispr is open")
    #expect(corrected("(Envious Wispr)", words) == "(EnviousWispr)", "outer decoration is kept")
  }

  @Test("a saved split alias is not matched across punctuation")
  func aliasStopsAtPunctuation() {
    let words = [CustomWord(canonical: "Notion AI", aliases: ["notion ay eye"])]
    #expect(corrected("check notion. ay eye", words) == "check notion. ay eye")
    #expect(corrected("check notion ay eye", words) == "check Notion AI")
  }

  @Test("ordinary small words never join into a saved name")
  func stopwordsNeverJoin() {
    let words = [CustomWord(canonical: "Justin"), CustomWord(canonical: "Brandon")]
    for sentence in ["bring it just in case", "the brand on the box"] {
      #expect(corrected(sentence, words) == sentence, "\(sentence)")
    }
  }

  /// Codex review: a saved name that contains a small word still gets its casing fixed.
  @Test("a saved name with a small word in it still gets its capitals")
  func spacedNameCasingStillFixed() {
    let words = [CustomWord(canonical: "Bank of America"), CustomWord(canonical: "The Who")]
    #expect(corrected("I called bank of america", words) == "I called Bank of America")
    #expect(corrected("I saw the who live", words) == "I saw The Who live")
  }

  @Test("the boundary rule allows outer decoration and refuses inner punctuation")
  func boundaryPredicate() {
    func crosses(_ tokens: [String]) -> Bool {
      WordCorrector.sliceCrossesPunctuation(tokens[...])
    }
    #expect(!crosses(["open"]), "a single token has no inner boundary")
    #expect(!crosses(["(open", "AI)."]))
    #expect(crosses(["open.", "AI"]))
    #expect(crosses(["open,", "AI"]))
    #expect(crosses(["open", "-", "AI"]))
    #expect(crosses(["open", "\"AI"]))
    #expect(!crosses(["open", "AI's"]), "an apostrophe inside a word is not a boundary")
  }

  @Test("the stopword rule only applies to several tokens")
  func stopwordPredicate() {
    #expect(WordCorrector.sliceContainsStopword(["a", "PI"][...]))
    #expect(WordCorrector.sliceContainsStopword(["just", "in"][...]))
    #expect(!WordCorrector.sliceContainsStopword(["open", "AI"][...]))
    #expect(!WordCorrector.sliceContainsStopword(["the"][...]))
    #expect(!WordCorrector.sliceContainsStopword(["open", "a", "i"][...]), "spelled letters")
    #expect(!WordCorrector.sliceContainsStopword(["a", "p", "i"][...]), "spelled letters")
    #expect(WordCorrector.joinsThroughStopword(["a", "PI"][...], canonical: "API"))
    #expect(!WordCorrector.joinsThroughStopword(["bank", "of", "america"][...], canonical: "Bank of America"))
  }
}
