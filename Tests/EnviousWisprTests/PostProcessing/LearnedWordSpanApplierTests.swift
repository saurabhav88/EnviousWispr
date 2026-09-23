import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

@Suite("Learned word span applier (#3105)", .tags(.productOutcome))
struct LearnedWordSpanApplierTests {
  @Test("one approved twist spot changes while Tuist stays as written")
  func oneApprovedSpot() throws {
    let text = "The plot twist made Tuist famous."
    let range = try #require(text.range(of: "twist"))
    let question = LearnedWordCheckQuestion(id: 0, sentence: text, range: range, word: "Tuist")

    let result = LearnedWordSpanApplier.apply(
      text: text, questions: [question],
      decisions: [LearnedWordCheckDecision(questionID: 0, approved: true)],
      scoresComparable: false)
    #expect(result.text == "The plot Tuist made Tuist famous.")
    #expect(result.applied == 1)
    #expect(result.contested == 0)
  }

  @Test("nested approvals for one word keep the shortest span")
  func nestedSameWord() throws {
    let text = "my Awdy arrived"
    let broad = try #require(text.range(of: "my Awdy"))
    let narrow = try #require(text.range(of: "Awdy"))
    let questions = [
      LearnedWordCheckQuestion(id: 0, sentence: text, range: broad, word: "Audi"),
      LearnedWordCheckQuestion(id: 1, sentence: text, range: narrow, word: "Audi")
    ]
    let decisions = [
      LearnedWordCheckDecision(questionID: 0, approved: true),
      LearnedWordCheckDecision(questionID: 1, approved: true)
    ]

    let result = LearnedWordSpanApplier.apply(
      text: text, questions: questions, decisions: decisions, scoresComparable: false)
    #expect(result.text == "my Audi arrived")
    #expect(result.applied == 1)
    #expect(result.contested == 0)
  }

  @Test("competing words need comparable scores to choose a winner")
  func crossWordOverlap() throws {
    let text = "Awdy arrived"
    let range = try #require(text.range(of: "Awdy"))
    let questions = [
      LearnedWordCheckQuestion(id: 0, sentence: text, range: range, word: "Audi"),
      LearnedWordCheckQuestion(id: 1, sentence: text, range: range, word: "Howdy")
    ]
    let decisions = [
      LearnedWordCheckDecision(questionID: 0, approved: true, score: 0.9),
      LearnedWordCheckDecision(questionID: 1, approved: true, score: 0.4)
    ]

    let scored = LearnedWordSpanApplier.apply(
      text: text, questions: questions, decisions: decisions, scoresComparable: true)
    #expect(scored.text == "Audi arrived")
    #expect(scored.applied == 1)
    #expect(scored.contested == 0)

    let unscored = LearnedWordSpanApplier.apply(
      text: text, questions: questions, decisions: decisions, scoresComparable: false)
    #expect(unscored.text == "Awdy arrived")
    #expect(unscored.applied == 0)
    #expect(unscored.contested == 2)

    let tied = LearnedWordSpanApplier.apply(
      text: text, questions: questions,
      decisions: [
        LearnedWordCheckDecision(questionID: 0, approved: true, score: 0.9),
        LearnedWordCheckDecision(questionID: 1, approved: true, score: 0.9)
      ], scoresComparable: true)
    #expect(tied.text == "Awdy arrived")
    #expect(tied.contested == 2)

    let missingScore = LearnedWordSpanApplier.apply(
      text: text, questions: questions,
      decisions: [
        LearnedWordCheckDecision(questionID: 0, approved: true, score: 0.9),
        LearnedWordCheckDecision(questionID: 1, approved: true)
      ], scoresComparable: true)
    #expect(missingScore.text == "Awdy arrived")
    #expect(missingScore.contested == 2)
  }

  @Test("unknown and duplicate decision IDs cannot change text")
  func invalidDecisions() throws {
    let text = "Awdy arrived"
    let range = try #require(text.range(of: "Awdy"))
    let question = LearnedWordCheckQuestion(id: 0, sentence: text, range: range, word: "Audi")
    let result = LearnedWordSpanApplier.apply(
      text: text, questions: [question], decisions: [
        LearnedWordCheckDecision(questionID: 99, approved: true),
        LearnedWordCheckDecision(questionID: 0, approved: true),
        LearnedWordCheckDecision(questionID: 0, approved: true)
      ], scoresComparable: false)
    #expect(result.text == "Awdy arrived")
    #expect(result.applied == 0)
  }

  @Test("a span outside the input cannot change text")
  func invalidRange() {
    let text = "Awdy arrived"
    let longer = "Awdy arrived much later"
    let start = longer.index(longer.startIndex, offsetBy: 16)
    let question = LearnedWordCheckQuestion(
      id: 0, sentence: text, range: start..<longer.endIndex, word: "Audi")
    let result = LearnedWordSpanApplier.apply(
      text: text, questions: [question],
      decisions: [LearnedWordCheckDecision(questionID: 0, approved: true)],
      scoresComparable: false)
    #expect(result.text == "Awdy arrived")
    #expect(result.applied == 0)
  }

  @Test("two approvals apply from right to left")
  func rightToLeft() throws {
    let text = "Awdy and day toast"
    let first = try #require(text.range(of: "Awdy"))
    let second = try #require(text.range(of: "day toast"))
    let questions = [
      LearnedWordCheckQuestion(id: 0, sentence: text, range: first, word: "Audi"),
      LearnedWordCheckQuestion(id: 1, sentence: text, range: second, word: "Tuist")
    ]
    let result = LearnedWordSpanApplier.apply(
      text: text, questions: questions, decisions: [
        LearnedWordCheckDecision(questionID: 0, approved: true),
        LearnedWordCheckDecision(questionID: 1, approved: true)
      ], scoresComparable: false)
    #expect(result.text == "Audi and Tuist")
    #expect(result.applied == 2)
    #expect(result.contested == 0)
  }

  @Test("empty inputs leave text untouched")
  func emptyInputs() {
    let result = LearnedWordSpanApplier.apply(
      text: "Awdy", questions: [], decisions: [], scoresComparable: false)
    #expect(result.text == "Awdy")
    #expect(result.applied == 0)
    #expect(result.contested == 0)
  }
}
