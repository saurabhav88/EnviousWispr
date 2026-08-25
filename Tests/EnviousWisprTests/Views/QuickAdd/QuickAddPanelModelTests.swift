import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2381 — which row the Return key accepts, and what accepting writes.
///
/// When this fails the user presses Return once and the wrong thing happens: a word they never chose
/// gains a spelling, or the spelling saved is what they TYPED to find the word rather than what they
/// selected. Both are silent — the library is written correctly-shaped, and only the next dictation
/// shows it.
///
/// **A focused search field and a preselected row both want Return, and the collision is invisible
/// until someone types.** That is the whole reason this state machine exists apart from the view: it
/// can be driven through every keyboard state without a window, a run loop, or the real library.
///
/// The two ranking calls are injected so each case can hand the model exactly the list that makes a
/// rule visible, rather than whatever the real scorer returns for a fixture chosen to be realistic.
@MainActor
@Suite("Quick Add panel keyboard contract — #2381", .tags(.productOutcome))
struct QuickAddPanelModelTests {

  private func candidate(_ canonical: String, aliases: [String] = []) -> QuickAddRanker.Candidate {
    QuickAddRanker.Candidate(
      word: CustomWord(canonical: canonical, aliases: aliases),
      score: 0.9,
      alreadyHasHeardSpelling: false)
  }

  private func ranking(_ names: [String], preselecting index: Int?) -> QuickAddRanker.Ranking {
    let rows = names.map { candidate($0) }
    return QuickAddRanker.Ranking(
      candidates: rows, preselectedID: index.map { rows[$0].id })
  }

  /// A model whose two ranking calls are recorded, so a case can assert WHICH question was asked.
  private final class Calls {
    var heard: [String] = []
    var searches: [(query: String, heard: String)] = []
  }

  private func makeModel(
    heard: String = "codecs",
    refusal: SelectionReader.Refusal? = nil,
    heardRanking: QuickAddRanker.Ranking,
    searchRanking: QuickAddRanker.Ranking = .empty
  ) -> (QuickAddPanelModel, Calls) {
    let calls = Calls()
    let model = QuickAddPanelModel(
      heard: heard,
      refusal: refusal,
      rankHeard: { heardString in
        calls.heard.append(heardString)
        return heardRanking
      },
      searchLibrary: { query, heardString in
        calls.searches.append((query, heardString))
        return searchRanking
      })
    return (model, calls)
  }

  // MARK: - Opening

  @Test("Opening ranks the heard word and nothing else")
  func openingRanksTheHeardWord() {
    let (model, calls) = makeModel(heardRanking: ranking(["Codex", "Claude Code"], preselecting: 0))

    #expect(calls.heard == ["codecs"])
    #expect(calls.searches.isEmpty)
    #expect(model.ranking.candidates.count == 2)
    #expect(model.acceptTarget?.word.canonical == "Codex")
  }

  @Test("A refusal opens the panel with no ranking, and does not rank nothing")
  func aRefusalRanksNothing() {
    // The panel still opens — it never silently does nothing — but there is no selection to rank, so
    // asking the ranker would be asking about an empty string.
    let (model, calls) = makeModel(
      heard: "",
      refusal: .selectionUnavailable,
      heardRanking: ranking(["Codex"], preselecting: 0))

    #expect(calls.heard.isEmpty)
    #expect(model.ranking.candidates.isEmpty)
    #expect(model.acceptTarget == nil)
    #expect(model.refusal == .selectionUnavailable)
  }

  @Test("Below the bar nothing is highlighted, so Return writes nothing")
  func belowTheBarReturnWritesNothing() {
    let (model, _) = makeModel(heardRanking: ranking(["Codex", "Claude Code"], preselecting: nil))

    #expect(!model.ranking.candidates.isEmpty, "the user still gets a list")
    #expect(model.acceptTarget == nil)
  }

  // MARK: - The search field

  @Test("Typing asks the search question, with the heard word carried alongside")
  func typingSearches() {
    let (model, calls) = makeModel(
      heardRanking: ranking(["Codex"], preselecting: 0),
      searchRanking: ranking(["codec"], preselecting: 0))

    model.updateQuery("codec")

    #expect(calls.searches.count == 1)
    #expect(calls.searches.first?.query == "codec")
    #expect(calls.searches.first?.heard == "codecs", "the search must know what will be written")
    #expect(model.ranking.candidates.first?.word.canonical == "codec")
  }

  @Test("Clearing the field restores the heard ranking, not an empty list")
  func clearingRestoresTheHeardRanking() {
    // The panel must not become a dead end when the user deletes what they typed.
    let (model, calls) = makeModel(
      heardRanking: ranking(["Codex"], preselecting: 0),
      searchRanking: ranking(["codec"], preselecting: 0))

    model.updateQuery("codec")
    model.updateQuery("")

    #expect(model.ranking.candidates.first?.word.canonical == "Codex")
    #expect(model.acceptTarget?.word.canonical == "Codex", "the confidence preselection comes back")
    #expect(calls.heard.count == 2, "re-ranked, not restored from a stale copy")
  }

  @Test("A whitespace-only query is a cleared field, not a search for spaces")
  func whitespaceQueryRestoresTheHeardRanking() {
    let (model, calls) = makeModel(
      heardRanking: ranking(["Codex"], preselecting: 0),
      searchRanking: ranking(["codec"], preselecting: 0))

    model.updateQuery("   ")

    #expect(calls.searches.isEmpty)
    #expect(model.ranking.candidates.first?.word.canonical == "Codex")
  }

  @Test("Typing never changes what would be written")
  func typingNeverChangesWhatIsWritten() {
    // The sharpest hazard the search field introduces: accepting a searched-for row must save the
    // ORIGINAL selection, not the query used to find it. Otherwise the escape hatch built to recover
    // from a wrong ranking becomes a way to write an arbitrary string.
    let (model, _) = makeModel(
      heardRanking: ranking(["Codex"], preselecting: 0),
      searchRanking: ranking(["codec"], preselecting: 0))

    model.updateQuery("something else entirely")

    #expect(model.spellingToWrite == "codecs")
    #expect(model.heard == "codecs")
  }

  @Test("A refused write is held on the model, so the panel that stayed open can say why")
  func aRefusedWriteIsHeld() {
    let (model, _) = makeModel(heardRanking: ranking(["Codex"], preselecting: 0))

    #expect(model.writeFailure == nil)
    model.noteWriteFailure("That word cannot be saved.")
    #expect(model.writeFailure == "That word cannot be saved.")
  }

  @Test("Typing clears a write failure, because it describes the accept the user has moved on from")
  func typingClearsAWriteFailure() {
    let (model, _) = makeModel(
      heardRanking: ranking(["Codex"], preselecting: 0),
      searchRanking: ranking(["Codex"], preselecting: nil))
    model.noteWriteFailure("That word cannot be saved.")

    model.updateQuery("cod")

    #expect(model.writeFailure == nil)
  }

  @Test("A refusal leaves the search field inert rather than ranking an empty selection")
  func searchIsInertUnderARefusal() {
    let (model, calls) = makeModel(
      heard: "",
      refusal: .accessibilityNotTrusted,
      heardRanking: ranking(["Codex"], preselecting: 0),
      searchRanking: ranking(["codec"], preselecting: 0))

    model.updateQuery("codec")

    #expect(calls.searches.isEmpty)
    #expect(model.query == "codec", "the text still shows; only the ranking is withheld")
    #expect(model.acceptTarget == nil)
  }

  // MARK: - Arrows

  @Test("Down from no highlight opts into the FIRST row")
  func downFromNoHighlightTakesTheFirst() {
    // Below the bar nothing is highlighted. An arrow press is the user deliberately opting in, which
    // is a different act from Return and is allowed to select where Return was not.
    let (model, _) = makeModel(heardRanking: ranking(["Codex", "Claude Code"], preselecting: nil))

    model.moveHighlight(by: 1)

    #expect(model.acceptTarget?.word.canonical == "Codex")
  }

  @Test("Up from no highlight opts into the LAST row")
  func upFromNoHighlightTakesTheLast() {
    let (model, _) = makeModel(heardRanking: ranking(["Codex", "Claude Code"], preselecting: nil))

    model.moveHighlight(by: -1)

    #expect(model.acceptTarget?.word.canonical == "Claude Code")
  }

  @Test("The highlight clamps at both ends rather than wrapping")
  func theHighlightClamps() {
    // Wrapping from the last row to the first is a surprise when the list is short and the user is
    // holding the key — and this list is at most a handful of rows.
    let (model, _) = makeModel(
      heardRanking: ranking(["Codex", "Claude Code", "Claude.md"], preselecting: 0))

    model.moveHighlight(by: -1)
    #expect(model.acceptTarget?.word.canonical == "Codex", "already at the top")

    model.moveHighlight(by: 1)
    model.moveHighlight(by: 1)
    model.moveHighlight(by: 1)
    #expect(model.acceptTarget?.word.canonical == "Claude.md", "already at the bottom")
  }

  @Test("Arrows on an empty list do nothing rather than trapping")
  func arrowsOnAnEmptyListDoNothing() {
    let (model, _) = makeModel(heardRanking: .empty)

    model.moveHighlight(by: 1)
    model.moveHighlight(by: -1)

    #expect(model.acceptTarget == nil)
    #expect(model.ranking.candidates.isEmpty)
  }

  @Test("The highlight is always a row that is on screen")
  func theHighlightIsAlwaysVisible() throws {
    let (model, _) = makeModel(heardRanking: ranking(["Codex", "Claude Code"], preselecting: nil))

    model.moveHighlight(by: 1)
    let id = try #require(model.ranking.preselectedID)

    #expect(model.ranking.candidates.contains { $0.id == id })
  }
  // MARK: - Which sentence the group header says (#2381, the command-bar layout)

  private func headerState(
    heard: String = "codecs",
    refusal: SelectionReader.Refusal? = nil,
    heardRanking: QuickAddRanker.Ranking,
    query: String = ""
  ) -> QuickAddPanelCopy.GroupHeaderState {
    let (model, _) = makeModel(
      heard: heard, refusal: refusal, heardRanking: heardRanking, searchRanking: heardRanking)
    if !query.isEmpty { model.updateQuery(query) }
    let view = QuickAddPanelView(
      model: model, onAccept: { _ in }, onCreateNew: {}, onCancel: {})
    return view.headerState
  }

  @Test("A preselected row means the header states the verb")
  func headerIsConfidentWhenARowIsPreselected() {
    #expect(headerState(heardRanking: ranking(["Codex"], preselecting: 0)) == .confident)
  }

  @Test("No preselection means the header says there is no close match")
  func headerIsLowConfidenceWithNoPreselection() {
    // The confidence bar's whole job, said in words. Without this the two states look identical
    // apart from a missing tint, which is not a signal anyone reads.
    #expect(headerState(heardRanking: ranking(["Codex"], preselecting: nil)) == .lowConfidence)
  }

  @Test("Typing keeps the verb, so the header cannot rewrite itself mid-keystroke")
  func headerStaysConfidentWhileSearching() {
    #expect(
      headerState(heardRanking: ranking(["Codex"], preselecting: 0), query: "cod") == .searching)
  }

  @Test("A preselected row that already has the spelling changes what the header says")
  func headerIsAlreadySavedWhenTheTopRowHasIt() {
    // The state the view never used to read at all. It outranks the others deliberately: if the
    // preselected row cannot add anything, a header promising an add is the defect this closes.
    let owned = QuickAddRanker.Candidate(
      word: CustomWord(canonical: "Codex", aliases: ["codecs"]),
      score: 1.0,
      alreadyHasHeardSpelling: true)
    let r = QuickAddRanker.Ranking(candidates: [owned], preselectedID: owned.id)

    #expect(headerState(heardRanking: r) == .alreadySaved)
  }

  @Test("Already-saved outranks searching, because typing does not make the row addable")
  func alreadySavedOutranksSearching() {
    // The paired ordering case. Without it the four-way `if` could be written in any order and
    // still pass every test above.
    let owned = QuickAddRanker.Candidate(
      word: CustomWord(canonical: "Codex", aliases: ["codecs"]),
      score: 1.0,
      alreadyHasHeardSpelling: true)
    let r = QuickAddRanker.Ranking(candidates: [owned], preselectedID: owned.id)

    #expect(headerState(heardRanking: r, query: "cod") == .alreadySaved)
  }
}
