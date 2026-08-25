import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #2381 — the ranking policy behind Quick Add's one-keypress accept.
///
/// When this fails the user selects a misheard word, presses Return once, and the spelling lands
/// on the wrong entry — or lands nowhere while the panel looked confident. Both are silent: the
/// library is written correctly-shaped, and the next dictation comes out wrong.
///
/// **Every score asserted here was measured with the shipped scorer**, canonical-only so each
/// fixture reproduces exactly (`WordCorrector.score`, weights 0.40/0.40/0.20). No number in this
/// file was estimated.
///
/// **No real string SCORES exactly 0.55** — 400,000 random pairs and every shipped pack spelling
/// against every pack canonical (1,928 x 391) produced none — so no fixture can sit on the
/// boundary. That is a fact about the scorer's reachable values, not about the boundary, which is a
/// property of the comparison and is asserted directly through `clearsConfidenceBar`. The measured
/// VALUE is pinned separately, because tests written against the named constant move with it and
/// would not notice the bar being changed.
@Suite("QuickAddRanker — #2381 which saved word does this mishearing belong to", .tags(.productOutcome))
struct QuickAddRankerTests {

  let ranker = QuickAddRanker()
  let corrector = WordCorrector()

  /// `Codex` as the user saved it, with the `codecs` spelling NOT yet on it — which is the only
  /// state a user is ever in when they reach for Quick Add.
  static let codex = CustomWord(canonical: "Codex")
  /// The shipped pack term that outscores it: `codecs` vs `codec` = 0.8889, vs `Codex` = 0.7333.
  static let codecPack = CustomWord(canonical: "codec", source: .pack)

  // MARK: - The user's own words outrank the packs

  @Test("A user's own word wins even when a pack term scores higher — the #2381 ship-blocker")
  func userWordOutranksAHigherScoringPackTerm() {
    let ranking = ranker.rank(
      heard: "codecs", userWords: [Self.codex], packTerms: [Self.codecPack])

    #expect(ranking.candidates.first?.word.canonical == "Codex")
    #expect(ranking.preselected?.word.canonical == "Codex")

    // The assertion that makes this discriminate: the pack term really does score HIGHER, so a
    // ranker that merged one pool would preselect `codec` and this test would go red.
    let userScore = corrector.score("codecs", against: "codex")
    let packScore = corrector.score("codecs", against: "codec")
    #expect(packScore > userScore, "fixture no longer reproduces the case it was built for")
    #expect(!ranking.candidates.contains { $0.isPackTerm })
  }

  @Test("A pack term is consulted only when no user word clears the bar")
  func packTermsEnterOnlyBelowTheBar() {
    // `dkr` vs `Docker` = 0.4000, below the bar; the pack's `Docker` copy carries the spelling and
    // so scores 1.0. With the user word below the bar, the pack is allowed to win.
    let userWord = CustomWord(canonical: "Docker")
    let packWord = CustomWord(canonical: "Dockerfile", aliases: ["dkr"], source: .pack)

    let ranking = ranker.rank(heard: "dkr", userWords: [userWord], packTerms: [packWord])

    #expect(corrector.score("dkr", against: "docker") < QuickAddRanker.confidenceBar)
    #expect(ranking.candidates.first?.word.canonical == "Dockerfile")
    #expect(ranking.candidates.first?.isPackTerm == true)
  }

  @Test("A pack term below the best user word does not displace it")
  func aWeakerPackTermNeverDisplacesTheUserWord() {
    // Both below the bar, user word higher. Packs are consulted and must lose.
    let userWord = CustomWord(canonical: "Docker")
    let packWord = CustomWord(canonical: "Zocor", source: .pack)

    let ranking = ranker.rank(heard: "dkr", userWords: [userWord], packTerms: [packWord])

    let userScore = corrector.score("dkr", against: "docker")
    let packScore = corrector.score("dkr", against: "zocor")
    #expect(userScore < QuickAddRanker.confidenceBar, "fixture must sit below the bar")
    #expect(packScore < userScore, "fixture must have the pack losing on raw score")
    #expect(ranking.candidates.first?.word.canonical == "Docker")
    #expect(ranking.preselectedID == nil, "nothing clears the bar, so Return must write nothing")
  }

  // MARK: - The confidence bar

  @Test("Below the bar the list still renders and NOTHING owns Return")
  func belowTheBarNothingIsPreselected() {
    let ranking = ranker.rank(
      heard: "dkr", userWords: [CustomWord(canonical: "Docker")], packTerms: [])

    #expect(corrector.score("dkr", against: "docker") < QuickAddRanker.confidenceBar)
    #expect(!ranking.candidates.isEmpty, "the user still gets a list to pick from")
    #expect(ranking.preselectedID == nil)
    #expect(ranking.preselected == nil)
  }

  @Test("Above the bar the top row owns Return")
  func aboveTheBarTheTopRowIsPreselected() {
    // `mongo` vs `MongoDB` = 0.6057.
    let ranking = ranker.rank(
      heard: "mongo", userWords: [CustomWord(canonical: "MongoDB")], packTerms: [])

    #expect(corrector.score("mongo", against: "mongodb") >= QuickAddRanker.confidenceBar)
    #expect(ranking.preselected?.word.canonical == "MongoDB")
  }

  @Test("An exact match is preselected")
  func anExactMatchIsPreselected() {
    let ranking = ranker.rank(
      heard: "codex", userWords: [Self.codex], packTerms: [])

    #expect(ranking.topScore == 1.0)
    #expect(ranking.preselected?.word.canonical == "Codex")
  }

  // MARK: - Nothing to rank

  @Test("An empty library ranks nothing and preselects nothing")
  func anEmptyLibraryRanksNothing() {
    let ranking = ranker.rank(heard: "codecs", userWords: [], packTerms: [])

    #expect(ranking.candidates.isEmpty)
    #expect(ranking.preselectedID == nil)
    #expect(ranking.topScore == nil)
  }

  @Test("A heard string matching nothing preselects nothing")
  func noMatchPreselectsNothing() {
    // `banana` vs `Docker` = 0.0000.
    let ranking = ranker.rank(
      heard: "banana", userWords: [CustomWord(canonical: "Docker")], packTerms: [])

    #expect(ranking.topScore == 0)
    #expect(ranking.preselectedID == nil)
  }

  @Test("An empty or whitespace-only selection ranks nothing rather than everything")
  func whitespaceOnlySelectionRanksNothing() {
    for heard in ["", "   ", "\n\t "] {
      let ranking = ranker.rank(heard: heard, userWords: [Self.codex], packTerms: [])
      #expect(ranking.candidates.isEmpty, "'\(heard)' must rank nothing")
      #expect(ranking.preselectedID == nil)
    }
  }

  @Test("Case and surrounding whitespace do not change the ranking")
  func selectionNormalizationIsIdempotent() {
    // A drag-select routinely picks up a trailing space; it must not cost a match.
    let plain = ranker.rank(heard: "codecs", userWords: [Self.codex], packTerms: [])
    let messy = ranker.rank(heard: "  Codecs\n", userWords: [Self.codex], packTerms: [])

    #expect(messy == plain)
  }

  // MARK: - Already saved

  @Test("A word that already carries the heard spelling is flagged rather than written again")
  func alreadySavedIsFlagged() {
    let saved = CustomWord(canonical: "Codex", aliases: ["codecs"])
    let other = CustomWord(canonical: "Claude Code")

    let ranking = ranker.rank(heard: "codecs", userWords: [saved, other], packTerms: [])

    #expect(ranking.candidates.first?.word.canonical == "Codex")
    #expect(ranking.candidates.first?.alreadyHasHeardSpelling == true)
    #expect(ranking.candidates.last?.alreadyHasHeardSpelling == false)
  }

  @Test("The flag reads the canonical too, not only the spellings")
  func alreadySavedMatchesTheCanonical() {
    let ranking = ranker.rank(heard: "Codex", userWords: [Self.codex], packTerms: [])

    #expect(ranking.candidates.first?.alreadyHasHeardSpelling == true)
  }

  // MARK: - The search field, which is the escape hatch

  @Test("Search reaches a term the heard ranking suppressed")
  func searchReachesASuppressedTerm() {
    // `rank` hides `codec` entirely, because a user word cleared the bar. If search inherited that
    // suppression the escape hatch would be shut in exactly the case it exists for.
    let ranked = ranker.rank(heard: "codecs", userWords: [Self.codex], packTerms: [Self.codecPack])
    #expect(!ranked.candidates.contains { $0.word.canonical == "codec" })

    let found = ranker.search(
      query: "codec", heard: "codecs", userWords: [Self.codex], packTerms: [Self.codecPack])
    #expect(found.candidates.contains { $0.word.canonical == "codec" })
  }

  @Test("Search ranks by the query and flags 'already saved' against the HEARD spelling")
  func searchSeparatesTheQueryFromTheHeardSpelling() throws {
    // The panel writes the heard spelling, never the query. The two strings differ here so a
    // ranker that conflated them would flag the wrong row.
    let saved = CustomWord(canonical: "Codex", aliases: ["codecs"])

    let found = ranker.search(
      query: "codex", heard: "codecs", userWords: [saved], packTerms: [])

    let row = try #require(found.candidates.first)
    #expect(row.word.canonical == "Codex")
    #expect(row.alreadyHasHeardSpelling == true, "flagged for 'codecs', which is what gets written")
  }

  @Test("An empty search query returns nothing, so the caller falls back to the heard ranking")
  func anEmptySearchQueryReturnsNothing() {
    let found = ranker.search(
      query: "  ", heard: "codecs", userWords: [Self.codex], packTerms: [Self.codecPack])

    #expect(found.candidates.isEmpty)
    #expect(found.preselectedID == nil)
  }

  @Test("The first search result owns Return even when it scores below the bar")
  func searchResultsAreAlwaysAcceptable() {
    // The bar governs a ranking the user did not ask for. A list they typed is one they chose, so
    // the row is acceptable even though `dkr` scores 0.4000 against `Docker`.
    let found = ranker.search(
      query: "dock", heard: "dkr", userWords: [CustomWord(canonical: "Docker")], packTerms: [])

    #expect(corrector.score("dkr", against: "docker") < QuickAddRanker.confidenceBar)
    #expect(found.preselected?.word.canonical == "Docker")
    #expect(found.topScore == corrector.score("dkr", against: "docker"),
            "a search row scores against what gets WRITTEN, not against what was typed")
  }

  @Test("A query matching nothing returns no rows, so Return writes nothing")
  func aQueryMatchingNothingReturnsNothing() {
    // The reason search filters instead of fuzzy-ranking. Fuzzy scoring gives EVERY word some
    // score, so it can never be empty: a query matching nothing would still render rows with the
    // first owning Return, and one keypress would write onto a word nobody looked for.
    let found = ranker.search(
      query: "xylophone",
      heard: "codecs",
      userWords: [Self.codex, CustomWord(canonical: "Docker")],
      packTerms: [Self.codecPack])

    #expect(found.candidates.isEmpty)
    #expect(found.preselectedID == nil)
  }

  @Test("A fragment reaches a longer word, which is what a search field is for")
  func aFragmentReachesALongerWord() {
    // `kub` scores poorly against `Kubernetes` under edit distance precisely because it is a
    // fragment, so a fuzzy search would bury the one word the user is typing towards.
    let kubernetes = CustomWord(canonical: "Kubernetes")
    let found = ranker.search(
      query: "kub", heard: "kubernetties", userWords: [kubernetes], packTerms: [])

    #expect(found.candidates.first?.word.canonical == "Kubernetes")
    #expect(corrector.score("kub", against: "kubernetes") < QuickAddRanker.confidenceBar,
            "fixture must be one a fuzzy search would have missed")
  }

  @Test("Search matches a saved spelling, not only the canonical")
  func searchMatchesSpellings() {
    let word = CustomWord(canonical: "Kubernetes", aliases: ["kates"])
    let found = ranker.search(query: "kate", heard: "kubernetties", userWords: [word], packTerms: [])

    #expect(found.candidates.first?.word.canonical == "Kubernetes")
  }

  @Test("Exact beats a canonical prefix, which beats a spelling prefix, which beats a substring")
  func matchTiersAreOrdered() {
    let exact = CustomWord(canonical: "code")
    let canonicalPrefix = CustomWord(canonical: "codex")
    let spellingPrefix = CustomWord(canonical: "Zulu", aliases: ["coder"])
    let substring = CustomWord(canonical: "barcode")

    let found = ranker.search(
      query: "code",
      heard: "codecs",
      userWords: [substring, spellingPrefix, canonicalPrefix, exact],
      packTerms: [],
      limit: 10)

    #expect(found.candidates.map(\.word.canonical) == ["code", "codex", "Zulu", "barcode"])
  }

  // MARK: - Structure

  @Test("A user override of a pack term is rendered once, as the user's copy")
  func aUserOverrideOfAPackTermIsNotRenderedTwice() {
    // `CustomWord.ownedByUser()` PRESERVES the id, so the moment Quick Add converts a pack term
    // the same id sits in both populations. Two rows with one id give SwiftUI duplicate
    // `Identifiable` ids and make a preselected id ambiguous.
    let packTerm = CustomWord(canonical: "codec", source: .pack)
    var override = packTerm.ownedByUser()
    override.aliases = ["codecs"]
    #expect(override.id == packTerm.id, "the collision this test exists for must still be real")

    let found = ranker.search(
      query: "codec", heard: "codecs", userWords: [override], packTerms: [packTerm])

    #expect(found.candidates.filter { $0.id == packTerm.id }.count == 1)
    #expect(found.candidates.first { $0.id == packTerm.id }?.isPackTerm == false)
  }

  @Test("The limit bounds the rows shown without changing which row wins")
  func theLimitBoundsTheRowsShown() {
    let library = (0..<20).map { CustomWord(canonical: "Docker\($0)") }

    let short = ranker.rank(heard: "docker0", userWords: library, packTerms: [], limit: 3)
    let long = ranker.rank(heard: "docker0", userWords: library, packTerms: [], limit: 10)

    #expect(short.candidates.count == 3)
    #expect(long.candidates.count == 10)
    #expect(short.candidates.first?.id == long.candidates.first?.id)
    #expect(short.preselectedID == long.preselectedID)
  }

  @Test("A zero or negative limit shows nothing rather than trapping")
  func aNonPositiveLimitShowsNothing() {
    for limit in [0, -1] {
      let ranking = ranker.rank(
        heard: "codecs", userWords: [Self.codex], packTerms: [], limit: limit)
      #expect(ranking.candidates.isEmpty)
      #expect(ranking.preselectedID == nil, "no row is on screen, so Return must write nothing")
    }
  }

  @Test("Equal scores order the user's word first and stay put across calls")
  func tiesAreOrderedAndStable() {
    // Two words scoring identically must not swap between redraws: a reorder under a highlight
    // changes what Return accepts without the user touching anything.
    let userWord = CustomWord(canonical: "codec")
    let packWord = CustomWord(canonical: "codec", source: .pack)

    let first = ranker.search(
      query: "codec", heard: "codecs", userWords: [userWord], packTerms: [packWord])
    let second = ranker.search(
      query: "codec", heard: "codecs", userWords: [userWord], packTerms: [packWord])

    #expect(first.candidates.map(\.id) == second.candidates.map(\.id))
    #expect(first.candidates.first?.isPackTerm == false, "the user's own word leads a tie")
  }

  @Test("Two entries alike on every ordering key keep their order when the input is reversed")
  func tiesSurviveAReversedInput() {
    // Same score, same source, same canonical — the case the comparator used to leave to
    // `Array.sorted`. Repeating one input order cannot observe it; reversing the input can.
    let a = CustomWord(canonical: "codec")
    let b = CustomWord(canonical: "codec")

    let forward = ranker.search(query: "codec", heard: "codecs", userWords: [a, b], packTerms: [])
    let reversed = ranker.search(query: "codec", heard: "codecs", userWords: [b, a], packTerms: [])

    #expect(forward.candidates.count == 2)
    #expect(forward.candidates.map(\.id) == reversed.candidates.map(\.id))
    #expect(forward.preselectedID == reversed.preselectedID)
  }

  @Test("The heard ranking resolves the same tie the same way in both input orders")
  func rankedTiesSurviveAReversedInput() {
    let a = CustomWord(canonical: "codec")
    let b = CustomWord(canonical: "codec")

    let forward = ranker.rank(heard: "codecs", userWords: [a, b], packTerms: [])
    let reversed = ranker.rank(heard: "codecs", userWords: [b, a], packTerms: [])

    #expect(forward.candidates.map(\.id) == reversed.candidates.map(\.id))
    #expect(forward.preselectedID == reversed.preselectedID)
  }

  @Test("The preselected id is always a row that is on screen")
  func thePreselectedRowIsAlwaysVisible() throws {
    let library = (0..<20).map { CustomWord(canonical: "Docker\($0)") }
    let ranking = ranker.rank(heard: "docker0", userWords: library, packTerms: [], limit: 2)

    // `try #require`, never a `guard ... else { return }`: the early return made this pass against
    // a ranker that preselected NOTHING, which is the one break it exists to catch.
    let id = try #require(ranking.preselectedID)
    #expect(ranking.candidates.contains { $0.id == id })
    #expect(ranking.preselected != nil)
  }

  @Test("A ranking cannot carry a highlight on a row that is not on screen")
  func anIdNamingNoVisibleRowIsDropped() {
    let visible = QuickAddRanker.Candidate(
      word: Self.codex, score: 1, alreadyHasHeardSpelling: false)

    let ranking = QuickAddRanker.Ranking(candidates: [visible], preselectedID: UUID())

    #expect(ranking.preselectedID == nil, "a highlight nobody can see would still accept on Return")
    #expect(ranking.preselected == nil)
  }

  // MARK: - The bar's value and its boundary

  @Test("The confidence bar is the measured value, not whatever the constant currently says")
  func theConfidenceBarIsTheMeasuredValue() {
    // Every other bar test compares against the named constant, so all of them move with it. This
    // is the one that does not: 0.55 is the lowest value at which confident-and-wrong is zero on
    // the user's own words in BOTH the warm and cold arms of the 1,648-mishearing sweep. Changing
    // it needs that sweep re-run, and this line is what makes the change say so.
    #expect(QuickAddRanker.confidenceBar == 0.55)
  }

  @Test("A score exactly AT the bar clears it")
  func theBoundaryIsInclusive() {
    // No fixture can reach 0.55 through the scorer, so the boundary is asserted where it lives.
    #expect(QuickAddRanker.clearsConfidenceBar(QuickAddRanker.confidenceBar))
    #expect(!QuickAddRanker.clearsConfidenceBar(QuickAddRanker.confidenceBar.nextDown))
    #expect(QuickAddRanker.clearsConfidenceBar(QuickAddRanker.confidenceBar.nextUp))
  }

  @Test("A library of only pack terms still renders a list")
  func aPackOnlyLibraryStillRenders() {
    // A brand-new user has no saved words. With `banana` scoring 0.0000 against `Docker`, a
    // strictly-greater test against a best user score of zero admitted nothing, so this user saw an
    // empty panel while everyone else saw their own zero-scoring rows.
    let ranking = ranker.rank(
      heard: "banana", userWords: [], packTerms: [CustomWord(canonical: "Docker", source: .pack)])

    #expect(corrector.score("banana", against: "docker") == 0)
    #expect(ranking.candidates.count == 1)
    #expect(ranking.candidates.first?.isPackTerm == true)
    #expect(ranking.preselectedID == nil, "nothing scored, so Return must still write nothing")
  }
}
