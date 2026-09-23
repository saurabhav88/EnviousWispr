#if DEBUG
  import EnviousWisprCore
  import Foundation
  import Testing

  @testable import EnviousWisprAppKit

  /// Class: product outcome. The drill must never change an unapproved spot.
  @Suite("Learned word check UAT door (#3105)", .tags(.productOutcome))
  @MainActor
  struct LearnedWordCheckUATDoorTests {
    @Test("comma-separated words are trimmed and deduplicated")
    func parseWords() throws {
      let words = try #require(
        LearnedWordCheckUATDoor.parseApprovedWords(" Tuist, Kotlin , Tuist "))
      #expect(words == Set(["Tuist", "Kotlin"]))
    }

    @Test("empty or whitespace-only lists are rejected")
    func rejectEmptyList() {
      #expect(LearnedWordCheckUATDoor.parseApprovedWords("") == nil)
      #expect(LearnedWordCheckUATDoor.parseApprovedWords("  , \t,\n ") == nil)
    }

    @Test("only listed words at spots that differ are approved")
    func approveListedChangedSpots() async throws {
      let words = try #require(LearnedWordCheckUATDoor.parseApprovedWords(" Tuist, Kotlin "))
      let checker = ScriptedLearnedWordChecker(approvedWords: words)
      let sentence = "toast Tuist kotlin"
      let questions = [
        LearnedWordCheckQuestion(
          id: 1, sentence: sentence, range: try #require(sentence.range(of: "toast")), word: "Tuist"
        ),
        LearnedWordCheckQuestion(
          id: 2, sentence: sentence, range: try #require(sentence.range(of: "Tuist")), word: "Tuist"
        ),
        LearnedWordCheckQuestion(
          id: 3, sentence: sentence, range: try #require(sentence.range(of: "kotlin")),
          word: "Kotlin"),
        LearnedWordCheckQuestion(
          id: 4, sentence: sentence, range: try #require(sentence.range(of: "toast")), word: "Rust"),
      ]
      let decisions = try await checker.decide(questions)
      #expect(checker.armName == "uat_scripted")
      #expect(checker.scoresAreComparable == false)
      #expect(decisions.map(\.approved) == [true, false, true, false])
      #expect(decisions.map(\.questionID) == [1, 2, 3, 4])
      #expect(decisions.allSatisfy { $0.score == nil })
    }
  }
#endif
