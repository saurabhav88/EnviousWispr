import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Stage-1 shape rule (#996 step 5): a casing-only or punctuation-only run
/// never reaches a judge. When this fails, the product asks the user to
/// remember "monday → Monday" or "its → it's", or drops a real brand join.
@Suite("EditRunShape — casing and punctuation-only runs (#996)", .tags(.productOutcome))
struct EditRunShapeTests {
  nonisolated static let dropped: [(String, String)] = [
    ("monday", "Monday"), ("figma", "Figma"), ("json", "JSON"), ("Github", "GitHub"),
    ("its", "it's"), ("hello", "hello!"), ("however", "however,"), ("the ceo", "the CEO"),
    ("Hello", "hello"), ("amanhã", "Amanhã"), ("sign up", "Sign Up"), ("e-mail", "E-Mail"),
    // #3258: a join or split made with punctuation.
    ("e mail", "e-mail"), ("well-known", "well known"), ("Miami Illinois", "Miami-Illinois"),
    ("node js", "node.js"), ("a b testing", "A/B testing"), ("U S", "U.S."), ("hello !", "hello!"), ("US", "U. S."),
  ]
  nonisolated static let kept: [(String, String)] = [
    ("post hog", "PostHog"), ("tail scale", "Tailscale"), ("e mail", "email"), ("git lab", "GitLab"), ("bird", "birds"),
    ("C plus plus", "C++"), ("A T and T", "AT&T"), ("Satz, Bau", "Satzbau"), ("tail scale", "Tailscale,"), ("hi, tail scale", "Hi, Tailscale"),
    ("Sarah", "Saira"), ("Mueller", "Müller"), ("pree yanka", "Priyanka"), ("tu", "tú"),
    ("same", "same"), ("", "x"), ("a b", "a b c"), ("अमित", "अमिता"), ("प्रियांका", "प्रियंका"),
  ]

  @Test("case, punctuation and symbol-only edits are shape-dropped", arguments: dropped)
  func drops(pair: (String, String)) {
    #expect(EditRunShape.isCasingOrPunctuationOnly(original: pair.0, replacement: pair.1), "\(pair.0) → \(pair.1)")
  }

  @Test("space-only joins, splits, spelling, diacritic and identical runs reach the judge", arguments: kept)
  func keeps(pair: (String, String)) {
    #expect(EditRunShape.isCasingOrPunctuationOnly(original: pair.0, replacement: pair.1) == false, "\(pair.0) → \(pair.1)")
  }

  @Test("a punctuated join in a real paste never becomes a judge run (#3258)")
  func punctuatedJoinThroughAlignment() {
    let result = EditAlignment.align(
      pasted: "We drove from Miami Illinois to the coast.", edited: "We drove from Miami-Illinois to the coast.")
    #expect(result.runs.isEmpty)
    #expect(result.dropped.map(\.reason) == [.casingOrPunctuationOnly])
    #expect(result.dropped.first?.run.replacement == "Miami-Illinois")
  }

  @Test("a space-only brand join in a real paste still reaches the judge")
  func spaceJoinThroughAlignment() {
    let result = EditAlignment.align(pasted: "I set up tail scale today.", edited: "I set up Tailscale today.")
    #expect(result.runs.map(\.coreReplacement) == ["Tailscale"])
    #expect(result.dropped.isEmpty)
  }
}
