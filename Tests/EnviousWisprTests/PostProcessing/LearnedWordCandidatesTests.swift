import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

@Suite("Learned word candidates (#3105)", .tags(.productOutcome))
struct LearnedWordCandidatesTests {
  @Test("only a misspelling the user fixed before is asked; a sound-alike never is")
  func aliasesOnly() {
    // Founder 2026-09-25: known aliases only. The checker cannot hear the audio, so a
    // correctly heard word that sounds like a learned one must never reach it.
    let tuist = [LearnedWord(canonical: "Tuist", observedMisspellings: ["Twoist"])]
    #expect(
      LearnedWordCandidates.questions(
        for: "The plot twist surprised me.", learned: tuist
      ).isEmpty)
    let sales = [LearnedWord(canonical: "EnviousSales", observedMisspellings: ["Envious Sales"])]
    #expect(
      LearnedWordCandidates.questions(
        for: "Expense tracking for Envious Labs and EnviousWispr.", learned: sales
      ).isEmpty)
    let kotlin = [LearnedWord(canonical: "Kotlin", observedMisspellings: [])]
    #expect(LearnedWordCandidates.questions(for: "rewrote it in cotton", learned: kotlin).isEmpty)
    let asked = LearnedWordCandidates.questions(
      for: "I code in Twoist every day", learned: tuist)
    #expect(asked.map(\.word) == ["Tuist"])
  }

  @Test("an exact common-word alias is still asked")
  func exactCommonWordAlias() {
    let text = "Please go home"
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: ["home"])]
    #expect(
      LearnedWordCandidates.questions(for: text, learned: learned)
        .contains { String(text[$0.range]) == "home" && $0.word == "Tuist" })
  }

  @Test("text already spelled as one of the user's words is never asked about")
  func settledSpellingsAreNotAsked() {
    // Founder live test 2026-09-25: a correct dictionary word was swapped for a learned
    // one. If a fix ever taught a real dictionary word as an alias ("Envious Labs" ->
    // "EnviousSales"), that word as dictated is still final.
    let sales = [LearnedWord(canonical: "EnviousSales", observedMisspellings: ["Envious Labs"])]
    let text = "Another session is updating expense tracking for Envious Labs."
    #expect(
      LearnedWordCandidates.questions(for: text, learned: sales).count == 1,
      "control: without the known spellings the alias is asked")
    let known = ["EnviousWispr", "EnviousStaging", "Envious Labs", "EnviousSales"]
    #expect(
      LearnedWordCandidates.questions(
        for: text, learned: sales, knownSpellings: known
      ).isEmpty,
      "a sentence-final period still ends the settled word")
    // Only exact, whole-word, exact-case text is settled: a lowercase mishearing is asked.
    let misheard = "Another session is updating expense tracking for envious labs today"
    #expect(
      LearnedWordCandidates.questions(
        for: misheard, learned: sales, knownSpellings: known
      ).count == 1)
  }

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

  @Test("an alias beside an already-correct Tuist is one question")
  func twistAndTuist() throws {
    let text = "The plot twist made Tuist famous."
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: ["twist"])]
    let questions = LearnedWordCandidates.questions(
      for: text, learned: learned, knownSpellings: ["Tuist"])
    let twist = try #require(
      questions.first { String(text[$0.range]) == "twist" && $0.word == "Tuist" })
    #expect(twist.sentence == "The plot twist made Tuist famous.")
    #expect(twist.rewritten == "The plot Tuist made Tuist famous.")
    #expect(questions.count == 1)
  }

  @Test("a multi-word observed misspelling is found")
  func observedMisspelling() throws {
    let text = "Please run coffee mug today."
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: ["coffee mug"])]
    let questions = LearnedWordCandidates.questions(for: text, learned: learned)
    let observed = try #require(questions.first { String(text[$0.range]) == "coffee mug" })
    #expect(observed.word == "Tuist")
    #expect(observed.rewritten == "Please run Tuist today.")
  }

  @Test("the same alias listed twice makes one question for the span")
  func duplicateCandidate() {
    let text = "day toast"
    let learned = [
      LearnedWord(canonical: "Tuist", observedMisspellings: ["day toast", "Day Toast"])
    ]
    let questions = LearnedWordCandidates.questions(for: text, learned: learned)
    #expect(
      questions.filter { String(text[$0.range]) == "day toast" && $0.word == "Tuist" }.count == 1)
  }

  @Test("an alias in another alphabet is found with whole-word boundaries")
  func nonLatinAlias() {
    let learned = [LearnedWord(canonical: "Tuist", observedMisspellings: ["туист"])]
    #expect(
      LearnedWordCandidates.questions(for: "я пишу в туист каждый день", learned: learned).count
        == 1)
    #expect(LearnedWordCandidates.questions(for: "я пишу в туисте", learned: learned).isEmpty)
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
    let exactOnly = LearnedWordCandidates.questions(for: "day toast", learned: learned, maxSpots: 1)
    #expect(exactOnly.count == 1)
    #expect(exactOnly.first?.id == 0)
    #expect(exactOnly.first?.rewritten == "Tuist")
  }

  @Test("the question budget keeps the earliest spots, whichever word they belong to")
  func budgetKeepsEarliestSpots() {
    // The first entry's alias repeats past the budget; the second entry's alias
    // comes first in the text and must still be asked.
    let learned = [
      LearnedWord(canonical: "Tuist", observedMisspellings: ["twist"]),
      LearnedWord(canonical: "Kotlin", observedMisspellings: ["cotton"]),
    ]
    let text = "cotton " + Array(repeating: "twist", count: 20).joined(separator: " ")
    let questions = LearnedWordCandidates.questions(for: text, learned: learned, maxSpots: 4)
    #expect(questions.map(\.word) == ["Kotlin", "Tuist", "Tuist", "Tuist"])
    #expect(questions.map(\.id) == [0, 1, 2, 3])
    #expect(questions.first.map { String(text[$0.range]) } == "cotton")
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

  // MARK: - #3518: a learned phrase that contains another learned word

  /// The founder's dictionary on 2026-10-07: `Saurabh` learned from several misspellings, then
  /// `Saurabhav` learned from `Saurabh A V`, the text the word check itself had produced.
  private static let founder = [
    LearnedWord(canonical: "Saurabh", observedMisspellings: ["Sarab", "Sarub", "Sorob"]),
    LearnedWord(canonical: "Saurabhav", observedMisspellings: ["Saurabh A V", "Sarov A V"]),
  ]
  private static let founderKnown = ["Saurabh", "Saurabhav"]

  private static func spots(_ text: String, _ questions: [LearnedWordCheckQuestion]) -> [String] {
    questions.map { "\(text[$0.range])->\($0.word)" }
  }

  @Test("#3518: a misspelling of the inner word inside a learned phrase is asked about")
  func composedAliasIsAsked() {
    let text = "My username is Sarab A V."
    let questions = LearnedWordCandidates.questions(
      for: text, learned: Self.founder, knownSpellings: Self.founderKnown)
    #expect(Self.spots(text, questions) == ["Sarab A V->Saurabhav", "Sarab->Saurabh"])
  }

  @Test("#3518: the learned phrase spelled with the user's own word is asked about")
  func literalPhraseContainingKnownWord() {
    let text = "My username is Saurabh A V."
    let questions = LearnedWordCandidates.questions(
      for: text, learned: Self.founder, knownSpellings: Self.founderKnown)
    #expect(Self.spots(text, questions) == ["Saurabh A V->Saurabhav"])
  }

  @Test("#3518: the inner word alone still gets only its own fix")
  func innerWordAlone() {
    let text = "Sarab will review it."
    let questions = LearnedWordCandidates.questions(
      for: text, learned: Self.founder, knownSpellings: Self.founderKnown)
    #expect(Self.spots(text, questions) == ["Sarab->Saurabh"])
    #expect(
      LearnedWordCandidates.questions(
        for: "Saurabh will review it.", learned: Self.founder, knownSpellings: Self.founderKnown
      ).isEmpty)
  }

  @Test("#3518: different spacing around the phrase is not the learned phrase")
  func spacingMustMatch() {
    let text = "My username is Sarab AV."
    let questions = LearnedWordCandidates.questions(
      for: text, learned: Self.founder, knownSpellings: Self.founderKnown)
    #expect(Self.spots(text, questions) == ["Sarab->Saurabh"])
  }

  @Test("#3518: punctuation and repeated spaces inside the phrase are kept exactly")
  func punctuationAndSpacingKept() {
    let learned = [
      LearnedWord(canonical: "Saurabh", observedMisspellings: ["Sarab"]),
      LearnedWord(canonical: "SaurabhTeam", observedMisspellings: ["Saurabh, team", "Saurabh  crew"]),
    ]
    let comma = "Thanks Sarab, team."
    #expect(
      Self.spots(comma, LearnedWordCandidates.questions(for: comma, learned: learned))
        == ["Sarab, team->SaurabhTeam", "Sarab->Saurabh"])
    let doubled = "Thanks Sarab  crew."
    #expect(
      Self.spots(doubled, LearnedWordCandidates.questions(for: doubled, learned: learned))
        == ["Sarab  crew->SaurabhTeam", "Sarab->Saurabh"])
    let single = "Thanks Sarab crew."
    #expect(
      Self.spots(single, LearnedWordCandidates.questions(for: single, learned: learned))
        == ["Sarab->Saurabh"])
  }

  @Test("#3518: a two-word learned word inside a phrase works, overlapping words never both change")
  func multiWordAndOverlappingInnerWords() {
    let learned = [
      LearnedWord(canonical: "Envious", observedMisspellings: ["envy us"]),
      LearnedWord(canonical: "Envious Labs", observedMisspellings: ["envious laps"]),
      LearnedWord(canonical: "EnviousLabsStudio", observedMisspellings: ["Envious Labs studio"]),
    ]
    let multi = "Made by envious laps studio."
    #expect(
      Self.spots(multi, LearnedWordCandidates.questions(for: multi, learned: learned))
        == ["envious laps studio->EnviousLabsStudio", "envious laps->Envious Labs"])
    let inner = "Made by envy us Labs studio."
    #expect(
      Self.spots(inner, LearnedWordCandidates.questions(for: inner, learned: learned))
        == ["envy us Labs studio->EnviousLabsStudio", "envy us->Envious"])
    let both = "Made by envy us laps studio."
    #expect(
      Self.spots(both, LearnedWordCandidates.questions(for: both, learned: learned))
        == ["envy us laps->Envious Labs", "envy us->Envious"],
      "the phrase needs both words changed at once, which never happens; Envious Labs' own alias composes")
  }

  @Test("#3518: text the expansion put there earns no exemption, and partial overlaps stay blocked")
  func exemptionNeedsTheRetainedInnerWord() {
    // Replacing Alpha by its learned alias Beta must not exempt a settled Beta.
    let learned = [
      LearnedWord(canonical: "Alpha", observedMisspellings: ["Beta"]),
      LearnedWord(canonical: "AlphaX", observedMisspellings: ["Alpha X"]),
    ]
    #expect(
      LearnedWordCandidates.questions(
        for: "We ship Beta X today.", learned: learned, knownSpellings: ["Beta"]
      ).isEmpty)
    #expect(
      Self.spots(
        "We ship Beta X today.",
        LearnedWordCandidates.questions(for: "We ship Beta X today.", learned: learned))
        == ["Beta X->AlphaX", "Beta->Alpha"],
      "control: without the settled Beta the composed phrase is asked")
    // A known word that only partly overlaps the phrase still blocks it.
    let partial = "My username is Saurabh A V Corp."
    #expect(
      Self.spots(
        partial,
        LearnedWordCandidates.questions(
          for: partial, learned: Self.founder, knownSpellings: Self.founderKnown + ["V Corp"]))
        == [])
    // The whole phrase spelled as a known word is final, as before (#3105).
    #expect(
      LearnedWordCandidates.questions(
        for: "My username is Saurabh A V.", learned: Self.founder,
        knownSpellings: Self.founderKnown + ["Saurabh A V"]
      ).isEmpty)
  }

  @Test("#3518: with a budget of one the longer fix is the one asked")
  func budgetPrefersTheLongerFix() {
    let text = "My username is Sarab A V."
    let questions = LearnedWordCandidates.questions(
      for: text, learned: Self.founder, maxSpots: 1, knownSpellings: Self.founderKnown)
    #expect(Self.spots(text, questions) == ["Sarab A V->Saurabhav"])
    let search = LearnedWordCandidates.search(
      for: text, learned: Self.founder, maxSpots: 1, knownSpellings: Self.founderKnown)
    #expect(search.composed == 1)
    #expect(search.truncated == 1)
  }

  @Test("#3518: at most 32 spellings per phrase, chosen the same way whatever the word order")
  func variantCapIsDeterministic() {
    let aliases = (0..<40).map { String(format: "a%02d", $0) }
    let inner = LearnedWord(canonical: "Inner", observedMisspellings: aliases.reversed())
    let outer = LearnedWord(canonical: "InnerX", observedMisspellings: ["Inner X"])
    for learned in [[inner, outer], [outer, inner]] {
      // The phrase as taught, then 31 replacements in byte order: a00 ... a30.
      #expect(
        LearnedWordCandidates.questions(for: "say a30 X now", learned: learned)
          .contains { $0.word == "InnerX" })
      #expect(
        !LearnedWordCandidates.questions(for: "say a31 X now", learned: learned)
          .contains { $0.word == "InnerX" })
    }
  }

  @Test("#3518: two entries for one word pool their misspellings")
  func duplicateCanonicalsMerge() {
    let learned = [
      LearnedWord(canonical: "Saurabh", observedMisspellings: ["Sarab"]),
      LearnedWord(canonical: "saurabh", observedMisspellings: ["Sorob"]),
      LearnedWord(canonical: "Saurabhav", observedMisspellings: ["Saurabh A V"]),
    ]
    for text in ["Hi Sarab A V.", "Hi Sorob A V."] {
      #expect(
        LearnedWordCandidates.questions(for: text, learned: learned)
          .contains { $0.word == "Saurabhav" })
    }
  }

  @Test("#3518: a phrase found only as taught counts as not composed")
  func composedCount() {
    let search = LearnedWordCandidates.search(
      for: "Hi Saurabh A V and Sarab A V.", learned: Self.founder,
      knownSpellings: Self.founderKnown)
    #expect(search.questions.filter { $0.word == "Saurabhav" }.count == 2)
    #expect(search.composed == 1)
    #expect(search.truncated == 0)
  }

  @Test("#3518: a learned word with punctuation inside a learned phrase is found (Codex diff review r1)")
  func punctuatedInnerWord() {
    let learned = [
      LearnedWord(canonical: "C++", observedMisspellings: ["see plus plus"]),
      LearnedWord(canonical: "cppav", observedMisspellings: ["C++ A V"]),
    ]
    let misheard = "Ping see plus plus A V today."
    #expect(
      Self.spots(misheard, LearnedWordCandidates.questions(for: misheard, learned: learned))
        == ["see plus plus A V->cppav", "see plus plus->C++"])
    let literal = "Ping C++ A V today."
    #expect(
      Self.spots(
        literal, LearnedWordCandidates.questions(for: literal, learned: learned, knownSpellings: ["C++"]))
        == ["C++ A V->cppav"])
  }

  @Test("#3518: a phrase of many overlapping learned words builds at most 32 spellings (Codex diff review r1)")
  func overlappingWordsStayBounded() {
    let phrase = Array(repeating: "ha", count: 28).joined(separator: " ")
    let variants = LearnedWordCandidates.variants(
      of: phrase, owner: "Laugh", misspellings: ["ha ha": ["ha"], "laugh": [phrase]])
    #expect(variants.count == 32)
    #expect(variants.first?.text == phrase)
  }

  @Test("#3518: inner learned words are found by the matcher's own word edges (Codex diff review r2)")
  func innerWordsUseTheMatchersWordEdges() {
    // A word joined to the next by punctuation, not a space.
    let slash = [
      LearnedWord(canonical: "Saurabh", observedMisspellings: ["Sarab"]),
      LearnedWord(canonical: "TeamHandle", observedMisspellings: ["Saurabh/team A V"]),
    ]
    let misheard = "Ping Sarab/team A V now."
    #expect(
      Self.spots(misheard, LearnedWordCandidates.questions(for: misheard, learned: slash))
        == ["Sarab/team A V->TeamHandle", "Sarab->Saurabh"])
    let literal = "Ping Saurabh/team A V now."
    #expect(
      Self.spots(
        literal,
        LearnedWordCandidates.questions(for: literal, learned: slash, knownSpellings: ["Saurabh"]))
        == ["Saurabh/team A V->TeamHandle"])
    // Two learned words that overlap inside the phrase: both are kept, so both settled
    // spellings are exempt where the phrase holds them as written.
    let overlap = [
      LearnedWord(canonical: "C", observedMisspellings: ["see"]),
      LearnedWord(canonical: "C++", observedMisspellings: ["see plus plus"]),
      LearnedWord(canonical: "cppav", observedMisspellings: ["C++ A V"]),
    ]
    let text = "Ping C++ A V today."
    #expect(
      Self.spots(
        text,
        LearnedWordCandidates.questions(for: text, learned: overlap, knownSpellings: ["C", "C++"]))
        == ["C++ A V->cppav"])
  }

  @Test("#3518: a phrase that is itself another learned word is not rebuilt from that word")
  func wholePhraseIsNotAnInnerWord() {
    let learned = [
      LearnedWord(canonical: "Envious Labs", observedMisspellings: ["envious laps"]),
      LearnedWord(canonical: "EnviousSales", observedMisspellings: ["Envious Labs"]),
    ]
    let text = "Invoices for envious laps today."
    #expect(
      Self.spots(text, LearnedWordCandidates.questions(for: text, learned: learned))
        == ["envious laps->Envious Labs"])
    #expect(
      LearnedWordCandidates.questions(
        for: "Invoices for Envious Labs today.", learned: learned,
        knownSpellings: ["Envious Labs", "EnviousSales"]
      ).isEmpty)
  }

  @Test("#3518: a phrase with no space expands; a phrase holding its own word does not (second-pass review)")
  func phrasesWithoutSpacesAndSelfWords() {
    let slash = [
      LearnedWord(canonical: "Saurabh", observedMisspellings: ["Sarab"]),
      LearnedWord(canonical: "TeamName", observedMisspellings: ["Saurabh/team"]),
    ]
    #expect(
      Self.spots("Ping Sarab/team.", LearnedWordCandidates.questions(for: "Ping Sarab/team.", learned: slash))
        == ["Sarab/team->TeamName", "Sarab->Saurabh"])
    // Two fixes to one word keep the shorter span (#3105), so the phrase taught for its own
    // word is not rebuilt: the answer does not depend on the question budget.
    let selfWord = [LearnedWord(canonical: "Saurabh", observedMisspellings: ["Sarab", "Saurabh A V"])]
    for budget in [1, 16] {
      #expect(
        Self.spots(
          "Hi Sarab A V.",
          LearnedWordCandidates.questions(for: "Hi Sarab A V.", learned: selfWord, maxSpots: budget))
          == ["Sarab->Saurabh"])
    }
  }

  @Test("#3518: a spot reachable as taught counts as taught whatever the alias order (second-pass review)")
  func composedCountIgnoresAliasOrder() {
    for outer in [["Saurabh A V", "Sarab A V"], ["Sarab A V", "Saurabh A V"]] {
      let learned = [
        LearnedWord(canonical: "Saurabh", observedMisspellings: ["Sarab"]),
        LearnedWord(canonical: "Saurabhav", observedMisspellings: outer),
      ]
      let search = LearnedWordCandidates.search(for: "Hi Sarab A V.", learned: learned)
      #expect(search.questions.contains { $0.word == "Saurabhav" })
      #expect(search.composed == 0)
    }
  }

  @Test("#3518: at the budget, a same-word phrase never displaces that word's shorter fix (Codex diff review r4)")
  func sameWordShorterFixKeepsItsPlace() {
    let learned = [LearnedWord(canonical: "Saurabh", observedMisspellings: ["Sarab", "Sarab A V"])]
    let text = "Hi Sarab A V."
    for budget in [1, 16] {
      #expect(
        Self.spots(text, LearnedWordCandidates.questions(for: text, learned: learned, maxSpots: budget))
          .first == "Sarab->Saurabh")
    }
  }
}
