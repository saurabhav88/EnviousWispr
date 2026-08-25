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

  /// **The field is HIDDEN under a refusal, not merely inert, and the copy guard depends on it.**
  /// `noRefusalPointsAtTheSearchField` forbids the refusal messages from naming a control the user
  /// cannot use; leaving a disabled field on screen is that control, still there. The test below
  /// covers the model half — the query text survives — and this covers whether it is shown at all.
  @Test("A refusal takes the search field off screen")
  func aRefusalHidesTheSearchField() {
    let (refused, _) = makeModel(
      heard: "", refusal: .accessibilityNotTrusted, heardRanking: .empty)
    #expect(!refused.showsSearchField)

    let (ordinary, _) = makeModel(heardRanking: ranking(["Codex"], preselecting: 0))
    #expect(ordinary.showsSearchField, "the ordinary panel is the two-way half of this")
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
      model: model, onAccept: { _ in }, onCreateNew: {}, onCreate: { _ in }, onCancel: {})
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
  @Test("Whitespace is not a search, at every reader")
  func whitespaceIsNotASearch() {
    // `updateQuery` trims before deciding whether to re-rank and stores the RAW text, because that
    // is what the field renders. So the heard ranking came back while four downstream readers still
    // believed a search was running: the header switched sentence under a user who typed nothing,
    // and `used_search=true` went out on the accept — a claim that the ranking needed rescuing when
    // it did not.
    let (model, _) = makeModel(
      heardRanking: ranking(["Codex"], preselecting: 0),
      searchRanking: ranking(["Codex"], preselecting: nil))

    model.updateQuery("   ")

    #expect(!model.isSearching)
    #expect(model.ranking.preselectedID != nil, "the heard ranking, including its preselection")
  }

  @Test("Real text IS a search")
  func realTextIsASearch() {
    // The paired positive. Without it, `isSearching` could return false always and the case above
    // would pass while the search field stopped being observable at all.
    let (model, _) = makeModel(
      heardRanking: ranking(["Codex"], preselecting: 0),
      searchRanking: ranking(["Codex"], preselecting: nil))

    model.updateQuery("cod")

    #expect(model.isSearching)
  }

  @Test("Text with surrounding whitespace is still a search")
  func paddedTextIsStillASearch() {
    // Trimming decides whether there is anything to search FOR; it must not decide that a padded
    // query is no query. A user who typed a space before their word is searching.
    let (model, _) = makeModel(
      heardRanking: ranking(["Codex"], preselecting: 0),
      searchRanking: ranking(["Codex"], preselecting: nil))

    model.updateQuery("  cod  ")

    #expect(model.isSearching)
  }

  // MARK: - Composing a new word (#2391 §2)

  /// The whole reason this stage exists. `Create a new word` presented a SwiftUI `.sheet`, and a
  /// sheet cannot present on a window that refuses main status — silently, with no exception and no
  /// log line. The button ran its action, set its binding, and changed nothing on screen. For a user
  /// with no readable selection it was the panel's ONLY control, so the panel had no working action
  /// at all.
  @Test("Create moves the panel to its compose stage")
  func createBeginsComposing() {
    let (model, _) = makeModel(heardRanking: ranking(["Codex"], preselecting: 0))

    model.beginComposing()

    #expect(model.stage == .composing)
  }

  /// Someone who typed a word, found nothing, and reached for Create has already said what they
  /// mean. Making them type it again is the panel forgetting.
  @Test("A search in progress seeds the draft, trimmed")
  func composingSeedsFromTheSearch() {
    let (model, _) = makeModel(
      heardRanking: ranking(["Codex"], preselecting: 0),
      searchRanking: ranking(["Codex"], preselecting: nil))

    model.updateQuery("  Qwen  ")
    model.beginComposing()

    #expect(model.draftCanonical == "Qwen")
  }

  /// **The misspelling is precisely what the new word must NOT be called**, so an empty field is the
  /// correct start. Seeding it with `heard` would put `clawwed` in the library as a canonical.
  @Test("With nothing typed the draft starts empty, never at the misspelling")
  func composingDoesNotSeedTheMisspelling() {
    let (model, _) = makeModel(
      heard: "clawwed", heardRanking: ranking(["Claude"], preselecting: 0))

    model.beginComposing()

    #expect(model.draftCanonical.isEmpty)
  }

  /// Whitespace is not a search. The same trimming rule `isSearching` owns, reaching the one place
  /// where getting it wrong writes a word rather than merely re-ranking a list.
  @Test("A whitespace-only field seeds nothing")
  func whitespaceQueryDoesNotSeedTheDraft() {
    let (model, _) = makeModel(heardRanking: ranking(["Codex"], preselecting: 0))

    model.updateQuery("   ")
    model.beginComposing()

    #expect(model.draftCanonical.isEmpty)
  }

  /// Escape has two meanings and the window cannot tell them apart, so the model answers.
  @Test("Escape belongs to the content while composing and to the window otherwise")
  func escapeIsConsumedOnlyWhileComposing() {
    let (model, _) = makeModel(heardRanking: ranking(["Codex"], preselecting: 0))

    #expect(model.consumeCancel() == false, "picking: the panel closes")

    model.beginComposing()
    #expect(model.consumeCancel() == true, "composing: back to the list")
    #expect(model.stage == .picking)
  }

  /// Backing out must not leave the next visit to Compose holding the last attempt's text or the
  /// last attempt's error.
  @Test("Backing out of composing clears the draft and the refusal")
  func cancellingComposingClearsState() {
    let (model, _) = makeModel(heardRanking: ranking(["Codex"], preselecting: 0))

    model.beginComposing()
    model.updateDraft("Qwen")
    model.noteWriteFailure("nope")
    model.cancelComposing()

    #expect(model.stage == .picking)
    #expect(model.draftCanonical.isEmpty)
    #expect(model.writeFailure == nil)
  }

  /// **The list is still ranked and still carries a preselected row while composing — only the view
  /// has stopped showing it.** A legend derived from `acceptTarget` would advertise `add spelling`
  /// over a compose field, and a stray Return would write to a row the user can no longer see.
  @Test("Return cannot accept a hidden row while composing")
  func composingWithdrawsTheAcceptTarget() {
    let (model, _) = makeModel(heardRanking: ranking(["Codex"], preselecting: 0))
    #expect(model.acceptTarget != nil)

    model.beginComposing()

    #expect(model.acceptTarget == nil)
    #expect(model.ranking.preselectedID != nil, "the ranking itself is untouched")
  }

  @Test("An empty or whitespace draft creates nothing")
  func anEmptyDraftIsNotAWord() {
    let (model, _) = makeModel(heardRanking: ranking(["Codex"], preselecting: 0))

    model.beginComposing()
    #expect(model.draftWord == nil)

    model.updateDraft("   ")
    #expect(model.draftWord == nil)
  }

  /// The whole point of authoring the word from HERE rather than from Settings: it arrives carrying
  /// the spelling the user selected.
  @Test("The authored word carries the heard spelling as its alias")
  func theDraftWordCarriesTheHeardSpelling() throws {
    let (model, _) = makeModel(
      heard: "clawwed", heardRanking: ranking(["Claude"], preselecting: 0))

    model.beginComposing()
    model.updateDraft("  Claude  ")
    let word = try #require(model.draftWord)

    #expect(word.canonical == "Claude")
    // "Claude" heard as "clawwed" — the alias is the mishearing, not the word.
    #expect(word.aliases == ["clawwed"])
  }

  /// A spelling identical to the canonical is not a mishearing, it is the word. Storing it as an
  /// alias of itself is a duplicate the library would carry forever, and nothing else would refuse
  /// it: `CustomWordsManager.add` has no rule against a word aliasing its own name.
  @Test("A spelling equal to the word is not stored as its own alias")
  func theDraftWordDropsASelfAlias() throws {
    let (model, _) = makeModel(
      heard: "Codex", heardRanking: ranking(["Codex"], preselecting: 0))

    model.beginComposing()
    model.updateDraft("codex")
    let word = try #require(model.draftWord)

    #expect(word.aliases.isEmpty)
  }

  /// **The state with no readable selection, which is the one Create exists for.** A blank alias
  /// here is what made `QuickAddWiring.newWordOutcome`'s postcondition vacuous — `kept` was empty,
  /// `missing.isEmpty` was trivially true, and a duplicate canonical took the success path having
  /// written nothing.
  @Test("With no selection the word is created carrying no spellings, not one blank one")
  func theDraftWordCarriesNoBlankAlias() throws {
    let (model, _) = makeModel(
      heard: "", refusal: .nothingSelected, heardRanking: .empty)

    model.beginComposing()
    model.updateDraft("Qwen")
    let word = try #require(model.draftWord)

    #expect(word.canonical == "Qwen")
    #expect(word.aliases.isEmpty)
  }

  /// A second `beginComposing` must not wipe what the user has typed. Reachable by clicking the
  /// create row again, which is still on screen in some layouts, and by any future caller.
  @Test("Composing is idempotent and does not discard the draft")
  func beginComposingTwiceKeepsTheDraft() {
    let (model, _) = makeModel(heardRanking: ranking(["Codex"], preselecting: 0))

    model.beginComposing()
    model.updateDraft("Qwen")
    model.beginComposing()

    #expect(model.draftCanonical == "Qwen")
  }

  // MARK: - Saying what happened and leaving (#2391 §1 and §3)

  private func covered(_ canonical: String) -> QuickAddRanker.Candidate {
    QuickAddRanker.Candidate(
      word: CustomWord(canonical: canonical, aliases: ["codecs"]),
      score: 1.0,
      alreadyHasHeardSpelling: true)
  }

  private func rankingCovered(preselecting: Bool) -> QuickAddRanker.Ranking {
    let rows = [covered("Codex"), candidate("Claude Code"), candidate("Qualtrics")]
    return QuickAddRanker.Ranking(
      candidates: rows, preselectedID: preselecting ? rows[0].id : nil)
  }

  /// The founder selected a word already covered and got a full picker offering nothing: a
  /// highlighted row whose only action is a no-op, three unrelated words presented as choices, and a
  /// dismissal he had to perform by hand — under a header that already said `nothing to add`.
  @Test("Opening onto a covered word says so instead of offering a picker")
  func openingOntoACoveredWordShowsANotice() throws {
    let (model, _) = makeModel(heardRanking: rankingCovered(preselecting: true))

    let notice = try #require(model.notice)
    #expect(notice.kind == .nothingToAdd)
    #expect(notice.word == "Codex")
    #expect(notice.spelling == "codecs")
    // The invocation has NOT resolved: the ranking can be wrong, and typing is how the user says so.
    #expect(notice.searchable)
  }

  /// **Below the confidence bar nothing is preselected, and the user must choose.** A notice there
  /// would answer a question the ranking deliberately refused to answer — and it would do it on the
  /// strength of a row that was never offered as the answer.
  @Test("A covered row that was not preselected does not shortcut the panel")
  func anUnpreselectedCoveredRowStillShowsTheList() {
    let (model, _) = makeModel(heardRanking: rankingCovered(preselecting: false))

    #expect(model.stage == .picking)
    #expect(model.notice == nil)
  }

  /// The escape hatch #2381 built for a wrong ranking has to survive a notice, or the notice becomes
  /// a dead end the user can only escape by pressing the shortcut again and seeing it again.
  @Test("Typing past the notice returns the full list")
  func typingLeavesTheNotice() {
    let (model, _) = makeModel(
      heardRanking: rankingCovered(preselecting: true),
      searchRanking: ranking(["Qualtrics"], preselecting: 0))

    model.updateQuery("qual")

    #expect(model.stage == .picking)
    #expect(model.notice == nil)
  }

  /// The same trimming rule `isSearching` owns. A space bar is not the user saying the ranking was
  /// wrong about them.
  @Test("Whitespace does not count as typing past the notice")
  func whitespaceDoesNotLeaveTheNotice() {
    let (model, _) = makeModel(heardRanking: rankingCovered(preselecting: true))

    model.updateQuery("   ")

    #expect(model.notice?.searchable == true)
  }

  /// The search field is on screen and focused during a searchable notice, so both ways into the
  /// list have to work. Only typing did — pressing Down watched nothing happen, on a panel visibly
  /// offering the key.
  @Test("An arrow past the notice opens the list, the same as typing")
  func arrowsLeaveTheNotice() {
    let (model, _) = makeModel(heardRanking: rankingCovered(preselecting: true))

    model.moveHighlight(by: 1)

    #expect(model.stage == .picking)
    #expect(model.notice == nil)
    #expect(model.acceptTarget != nil, "and the row it lands on is acceptable")
  }

  /// A notice is the panel saying it has nothing to ask. A Return arriving from anywhere while one
  /// is up must not write to the row still sitting preselected behind it.
  @Test("Return cannot accept a row behind a notice")
  func aNoticeWithdrawsTheAcceptTarget() {
    let (model, _) = makeModel(heardRanking: rankingCovered(preselecting: true))

    #expect(model.acceptTarget == nil)
    #expect(model.ranking.preselectedID != nil, "the ranking itself is untouched")
  }

  /// **A confirmation is NEVER searchable, and getting this backwards is the defect that nearly sent
  /// it to the dictation overlay instead.** It is shown after Return, when the user has gone back to
  /// their sentence; a focused field would eat the first letters of their next word.
  @Test("A post-Return confirmation offers no field to type into")
  func aConfirmationIsNotSearchable() throws {
    let (model, _) = makeModel(heardRanking: ranking(["Codex"], preselecting: 0))

    model.noteWriteFailure("stale")
    model.showNotice(.saved, spelling: "codecs", word: "Codex")

    let notice = try #require(model.notice)
    #expect(notice.searchable == false)
    #expect(notice.kind == .saved)
    #expect(model.writeFailure == nil, "the failure it replaces must not render underneath it")
  }

  /// A refusal has nothing to rank, so there is no covered row to shortcut on. Guards the branch
  /// order in the initialiser: reading the ranking before the refusal is handled would crash or,
  /// worse, notice on an empty string.
  @Test("A refusal never opens onto a notice")
  func aRefusalNeverNotices() {
    let (model, _) = makeModel(heard: "", refusal: .nothingSelected, heardRanking: .empty)

    #expect(model.stage == .picking)
    #expect(model.notice == nil)
  }
}
