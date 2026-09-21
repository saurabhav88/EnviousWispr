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
  ]
  nonisolated static let kept: [(String, String)] = [
    ("post hog", "PostHog"), ("e mail", "e-mail"), ("well-known", "well known"), ("git lab", "GitLab"), ("bird", "birds"),
    ("Sarah", "Saira"), ("Mueller", "Müller"), ("pree yanka", "Priyanka"), ("tu", "tú"),
    ("same", "same"), ("", "x"), ("a b", "a b c"), ("अमित", "अमिता"), ("प्रियांका", "प्रियंका"),
  ]

  @Test("case, punctuation and symbol-only edits are shape-dropped", arguments: dropped)
  func drops(pair: (String, String)) {
    #expect(EditRunShape.isCasingOrPunctuationOnly(original: pair.0, replacement: pair.1), "\(pair.0) → \(pair.1)")
  }

  @Test("joins, splits, spelling, diacritic and identical runs reach the judge", arguments: kept)
  func keeps(pair: (String, String)) {
    #expect(EditRunShape.isCasingOrPunctuationOnly(original: pair.0, replacement: pair.1) == false, "\(pair.0) → \(pair.1)")
  }
}
