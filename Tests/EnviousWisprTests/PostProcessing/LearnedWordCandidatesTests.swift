import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

@Suite("Learned word candidates (#3105)", .tags(.productOutcome))
struct LearnedWordCandidatesTests {
  @Test("learned provenance supplies only user and builtin words")
  func learnedProvenance() {
    let vocabulary = [
      CustomWord(
        canonical: "Tuist", aliases: ["day toast"], learnedAliases: ["day toast"],
        learnedAt: Date(timeIntervalSince1970: 1)),
      CustomWord(
        canonical: "Audi", aliases: ["manually typed"],
        learnedAliases: ["Awdy"]),
      CustomWord(canonical: "Queen", aliases: ["Qwen"]),
      CustomWord(
        canonical: "Posthog", aliases: ["post hoc"], source: .pack,
        learnedAliases: ["post hoc"], learnedAt: Date(timeIntervalSince1970: 1)),
    ]

    #expect(
      LearnedWordCandidates.learnedWords(from: vocabulary) == [
        LearnedWord(canonical: "Tuist", observedMisspellings: ["day toast"]),
        LearnedWord(canonical: "Audi", observedMisspellings: ["Awdy"]),
      ])
  }

  @Test("the sound spot beside an already-correct Tuist is one question")
  func twistAndTuist() throws {
    let text = "The plot twist made Tuist famous."
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: [])]
    let questions = LearnedWordCandidates.questions(for: text, learned: learned)
    let twist = try #require(
      questions.first { String(text[$0.range]) == "twist" && $0.word == "Tuist" })

    #expect(twist.sentence == "The plot twist made Tuist famous.")
    #expect(twist.rewritten == "The plot Tuist made Tuist famous.")
    #expect(questions.contains { String(text[$0.range]) == "Tuist" } == false)
  }

  @Test("an observed misspelling is found even when its sound does not match")
  func observedMisspelling() throws {
    let text = "Please run coffee mug today."
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: ["coffee mug"])]
    let soundOnly = LearnedWordSpotFinder().spots(
      in: text, words: LearnedWordSpotFinder.prepare(["Tuist"]), maxSpots: 16)
    #expect(soundOnly.contains { String(text[$0.range]) == "coffee mug" } == false)

    let questions = LearnedWordCandidates.questions(for: text, learned: learned)
    let observed = try #require(questions.first { String(text[$0.range]) == "coffee mug" })
    #expect(observed.word == "Tuist")
    #expect(observed.rewritten == "Please run Tuist today.")
  }

  @Test("an observed spelling and a sound match make one question for the same span")
  func duplicateCandidate() {
    let text = "day toast"
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: ["day toast"])]
    let questions = LearnedWordCandidates.questions(for: text, learned: learned)
    #expect(
      questions.filter { String(text[$0.range]) == "day toast" && $0.word == "Tuist" }.count == 1)
  }

  @Test("observed spelling is case insensitive but needs whole-token boundaries")
  func observedBoundaries() {
    let text = "DAY TOAST day toast-like day toasting"
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: ["day toast"])]
    let actual = LearnedWordCandidates.questions(for: text, learned: learned)
      .filter { $0.word == "Tuist" && String(text[$0.range]).lowercased() == "day toast" }
      .map { String(text[$0.range]) }
    #expect(actual == ["DAY TOAST"])
  }

  @Test("empty inputs have no questions")
  func emptyInputs() {
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: ["day toast"])]
    #expect(LearnedWordCandidates.learnedWords(from: []) == [])
    #expect(LearnedWordCandidates.questions(for: "", learned: learned) == [])
    #expect(LearnedWordCandidates.questions(for: "day toast", learned: []) == [])
    #expect(LearnedWordCandidates.questions(for: "day toast", learned: learned, maxSpots: 0) == [])
    // One shared budget, exact observed spellings first: a budget of one is the
    // exact spelling, never a sound match.
    let exactOnly = LearnedWordCandidates.questions(for: "day toast", learned: learned, maxSpots: 1)
    #expect(exactOnly.count == 1)
    #expect(exactOnly.first?.id == 0)
    #expect(exactOnly.first?.rewritten == "Tuist")
  }

  @Test("a sentence-ending period is a boundary; a dotted term is not (Codex PR-3 review)")
  func sentencePeriodIsABoundary() {
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: ["coffee mug"])]
    let text = "I left it on the coffee mug. Then coffee mug.io loaded."
    let spans = LearnedWordCandidates.questions(for: text, learned: learned)
      .filter { $0.word == "Tuist" && String(text[$0.range]) == "coffee mug" }
    #expect(spans.count == 1)
    #expect(spans.first.map { text[..<$0.range.lowerBound].hasSuffix("on the ") } == true)
  }

  @Test("each spot gets its own sentence while full-text spans stay intact")
  func sentenceContexts() throws {
    let text = "We use cotton daily. The plot twist surprised me."
    let learned = [
      LearnedWord(canonical: "Kotlin", observedMisspellings: ["cotton"]),
      LearnedWord(canonical: "Tuist", observedMisspellings: ["twist"]),
    ]
    let questions = LearnedWordCandidates.questions(for: text, learned: learned)
    let cotton = try #require(
      questions.first { $0.word == "Kotlin" && String(text[$0.range]) == "cotton" })
    let twist = try #require(
      questions.first { $0.word == "Tuist" && String(text[$0.range]) == "twist" })
    #expect(cotton.contextText == "We use cotton daily.")
    #expect(cotton.contextRewritten == "We use Kotlin daily.")
    #expect(twist.contextText == "The plot twist surprised me.")
    #expect(twist.contextRewritten == "The plot Tuist surprised me.")
    #expect(twist.sentence == text)
    #expect(twist.rewritten == "We use cotton daily. The plot Tuist surprised me.")
  }

  @Test("a dotted term stays in the spot's sentence")
  func dottedTermContext() throws {
    let text = "We opened mug.io with toast today. Then we left."
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: ["toast"])]
    let question = try #require(
      LearnedWordCandidates.questions(for: text, learned: learned)
        .first { $0.word == "Tuist" && String(text[$0.range]) == "toast" })
    #expect(question.contextText == "We opened mug.io with toast today.")
  }

  @Test("an initialism's final period does not end the sentence")
  func initialismContext() throws {
    let text = "I joined the U.S. arm me last year. Then I left."
    let learned = [LearnedWord(canonical: "Army", observedMisspellings: ["arm me"])]
    let question = try #require(
      LearnedWordCandidates.questions(for: text, learned: learned)
        .first { $0.word == "Army" && String(text[$0.range]) == "arm me" })
    #expect(question.contextText == "I joined the U.S. arm me last year.")
  }

  @Test("exclamation marks and ellipses end sentence context")
  func otherSentenceEnds() throws {
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: ["toast"])]
    for (text, expected) in [
      ("Please say toast! Then leave.", "Please say toast!"),
      ("Please say toast… Then leave.", "Please say toast…"),
    ] {
      let question = try #require(
        LearnedWordCandidates.questions(for: text, learned: learned)
          .first { $0.word == "Tuist" && String(text[$0.range]) == "toast" })
      #expect(question.contextText == expected)
    }
  }

  @Test("question marks and newlines end sentence context")
  func questionMarkAndNewlineContexts() throws {
    let text = "Did you say toast?\nThe plot twist surprised me."
    let learned = [
      LearnedWord(canonical: "Tuist", observedMisspellings: ["toast"]),
      LearnedWord(canonical: "Kotlin", observedMisspellings: ["twist"]),
    ]
    let questions = LearnedWordCandidates.questions(for: text, learned: learned)
    let toast = try #require(
      questions.first { $0.word == "Tuist" && String(text[$0.range]) == "toast" })
    let twist = try #require(
      questions.first { $0.word == "Kotlin" && String(text[$0.range]) == "twist" })
    #expect(toast.contextText == "Did you say toast?")
    #expect(twist.contextText == "The plot twist surprised me.")

    let newlineOnly = "Please say toast\nThen leave."
    let newlineQuestion = try #require(
      LearnedWordCandidates.questions(
        for: newlineOnly, learned: [learned[0]]
      )
      .first { $0.word == "Tuist" && String(newlineOnly[$0.range]) == "toast" })
    #expect(newlineQuestion.contextText == "Please say toast")
  }

  @Test("a long run-on take keeps a bounded context containing the spot")
  func longRunOnContext() throws {
    let filler = Array(repeating: "filler", count: 80).joined(separator: " ")
    let text = filler + " toast " + filler
    #expect(text.count > 1_000)
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: ["toast"])]
    let question = try #require(
      LearnedWordCandidates.questions(for: text, learned: learned)
        .first { $0.word == "Tuist" && String(text[$0.range]) == "toast" })
    #expect(question.contextText.count <= 420)
    #expect(question.contextText.contains("toast"))
    #expect(question.contextRewritten.contains("Tuist"))
    #expect(question.contextRange.lowerBound <= question.range.lowerBound)
    #expect(question.range.upperBound <= question.contextRange.upperBound)
  }

  @Test("one budget bounds every question, however often an alias repeats")
  func totalBudget() {
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: ["toast"])]
    let text = Array(repeating: "a toast", count: 200).joined(separator: " and ")
    #expect(LearnedWordCandidates.questions(for: text, learned: learned).count == 16)
  }
}
