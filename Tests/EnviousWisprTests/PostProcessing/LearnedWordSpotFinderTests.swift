import Foundation
import Testing

@testable import EnviousWisprPostProcessing

@Suite("Learned word spot finder (#3105)", .tags(.productOutcome))
struct LearnedWordSpotFinderTests {
  private struct Fixture: Decodable {
    let cases: [Case]

    struct Case: Decodable {
      let text: String
      let words: [String]
      let expected: [Expected]
    }

    struct Expected: Decodable {
      let spot: String
      let word: String
      let start: Int
      let end: Int
      let sim: Double
    }
  }

  @Test("every frozen Python sound match has the same word, text, scalar range and score")
  func pythonParity() throws {
    let url = RepoRoot.url.appending(
      path: "Tests/EnviousWisprTests/Resources/LearnedWordSpots/spot-parity.json")
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    try #require(fixture.cases.isEmpty == false)
    let finder = LearnedWordSpotFinder()
    for (caseIndex, row) in fixture.cases.enumerated() {
      let actual = finder.spots(
        in: row.text, words: LearnedWordSpotFinder.prepare(row.words), maxSpots: 16)
      guard actual.count == row.expected.count else {
        Issue.record("Case \(caseIndex): expected \(row.expected.count) spots, got \(actual.count): \(actual)")
        return
      }
      for (spotIndex, pair) in zip(actual, row.expected).enumerated() {
        let (got, want) = pair
        let scalars = row.text.unicodeScalars
        let start = scalars.distance(from: scalars.startIndex, to: got.range.lowerBound)
        let end = scalars.distance(from: scalars.startIndex, to: got.range.upperBound)
        let score = (got.similarity * 1000).rounded(.toNearestOrEven) / 1000
        guard Array(got.text.unicodeScalars) == Array(want.spot.unicodeScalars),
              Array(got.word.unicodeScalars) == Array(want.word.unicodeScalars),
              start == want.start, end == want.end, score == want.sim
        else {
          let message = "Case \(caseIndex), spot \(spotIndex): expected "
            + "\(want.spot.debugDescription) / \(want.word.debugDescription) "
            + "@\(want.start)..<\(want.end) = \(want.sim), got "
            + "\(got.text.debugDescription) / \(got.word.debugDescription) "
            + "@\(start)..<\(end) = \(score)"
          Issue.record("\(message)")
          return
        }
      }
    }
  }

  @Test("difflib longest-block tie breaking")
  func sequenceMatcherRatios() {
    #expect(LearnedWordSpotFinder.ratio("abcd", "bcde") == 0.75)
    #expect(LearnedWordSpotFinder.ratio("tide", "diet") == 0.25)
    #expect(LearnedWordSpotFinder.ratio("diet", "tide") == 0.5)
  }
}
