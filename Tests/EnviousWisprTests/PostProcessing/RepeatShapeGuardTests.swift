import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #3975 §3.2: a repeated fix skips the judge only when the corrected spelling
/// looks like a name, brand or term. Wrong here means a repeated everyday
/// rewrite learned without the judge, or a real name never learned by repeat.
/// Class: `.productOutcome`.
@Suite(.tags(.productOutcome)) struct RepeatShapeGuardTests {

  private func passes(_ corrected: String, at token: Int, in pasted: String) -> Bool {
    RepeatShapeGuard.passes(corrected: corrected, startToken: token, pasted: pasted)
  }

  @Test("a capital inside the sentence, an acronym, CamelCase or letters with a digit pass")
  func namesBrandsAndTermsPass() {
    let pasted = "we deployed on cooper netties with sify and team viewer at tele two"
    #expect(passes("Kubernetes", at: 3, in: pasted))
    #expect(passes("Sify", at: 6, in: pasted))
    #expect(passes("TeamViewer", at: 8, in: pasted))
    #expect(passes("Tele2", at: 11, in: pasted))
    // At a sentence start only a capital BEYOND the first letter counts.
    #expect(passes("CENIT", at: 0, in: "senate approved the budget"))
    #expect(passes("TeamViewer", at: 0, in: "team viewer is open"))
    #expect(passes("COP1", at: 0, in: "cop one starts now"))
  }

  @Test(
    "lowercase rewrites, bare numbers and a word capitalised only because a sentence starts never pass"
  )
  func everydayRewritesFail() {
    #expect(!passes("received", at: 1, in: "I got the file"))
    #expect(!passes("summarization", at: 2, in: "the summer ization step"))
    #expect(!passes("5", at: 2, in: "I need five more"))
    #expect(!passes("Nacala", at: 0, in: "Nikala is a port"))
    #expect(!passes("Nacala", at: 3, in: "It is big. Nikala is a port"))
    #expect(!passes("Nacala", at: 2, in: "Big port!\nNikala again"))
  }

  @Test("sentence start: first token, after . ! ? or a newline, and nowhere else")
  func sentenceStart() {
    let text = "One two. Three four! Five six? Seven\neight nine, ten"
    let starts = (0..<10).filter { RepeatShapeGuard.isSentenceStart(tokenIndex: $0, in: text) }
    #expect(starts == [0, 2, 4, 6, 7])
    #expect(!RepeatShapeGuard.isSentenceStart(tokenIndex: 99, in: text))
    #expect(RepeatShapeGuard.isSentenceStart(tokenIndex: 0, in: "  leading space"))
  }
}
