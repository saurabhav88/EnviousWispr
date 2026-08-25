import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

/// The Quick Add panel's state machine (#2381).
///
/// **Everything about which row owns the Return key lives here, and nothing about windows does.**
/// A focused search field and a preselected row both want Return, and the collision is invisible
/// until someone types — so the rule is one place, written down, and unit-tested without a panel.
///
/// The two ranking calls are injected rather than reached for. That is not ceremony: it keeps this
/// type free of the word library and lets every keyboard rule be exercised against candidate lists
/// chosen to make the rule visible, instead of whatever the real scorer happens to return.
@MainActor
@Observable
final class QuickAddPanelModel {

  /// What the user selected. **Immutable for the panel's lifetime** — typing in the search field
  /// changes which candidates are SHOWN and never what would be written.
  let heard: String

  /// Why there is no selection, or nil when there is one. The panel opens either way; it never
  /// silently does nothing.
  let refusal: SelectionReader.Refusal?

  /// What the user has typed. Navigation only.
  private(set) var query: String = ""

  /// Why the last accept did not save, or nil. **The panel stays open when this is set**, which is
  /// the whole point: the write path can refuse (the character policy, the 512-scalar ceiling, a
  /// words file that will not write) and a panel that dismissed on refusal reported success for a
  /// word that was never saved.
  private(set) var writeFailure: String?

  /// The rows on screen, and which one Return would accept.
  private(set) var ranking: QuickAddRanker.Ranking

  /// What the panel is asking the user right now.
  ///
  /// **A stage, not a second window.** `Create a new word` used to present a SwiftUI `.sheet`, and
  /// on this panel a sheet presents nothing at all: SwiftUI attaches one through
  /// `NSWindow.beginSheet`, which AppKit refuses on a window with `canBecomeMain = false`, silently
  /// (`swiftui-view-patterns.md` FACT: a-sheet-cannot-present-on-a-window-that-refuses-main-status).
  /// The panel must refuse main status — taking it reorders the windows the user was working in
  /// behind an accessory — so the fix is to stop needing a sheet rather than to flip a flag.
  ///
  /// Closed, so a new stage cannot inherit another's rules by falling into whichever branch is
  /// nearest.
  enum Stage: Equatable, Sendable {
    /// The ranked list plus the search field.
    case picking
    /// One field: the correct spelling for `heard`. Reached from the create row.
    case composing
    /// Nothing left to ask. The panel states what happened and takes itself away.
    case notice(Notice)
  }

  /// What the panel says when it has nothing further to ask.
  ///
  /// **Two situations reach this and they differ in ONE property, which is why it is a flag rather
  /// than two cases.** After Return the user has committed and gone back to their sentence, so the
  /// panel must give keyboard focus back before it fades — a confirmation that eats the first letter
  /// of their next word is worse than no confirmation. Opened onto a word that is already covered,
  /// the user has typed nothing and is looking straight at the panel, so the search field stays and
  /// typing returns them to the full list.
  ///
  /// Getting that backwards in either direction is a real defect — a terminal notice holding focus
  /// swallows keystrokes, and a searchable one that dropped focus would make the escape hatch
  /// unreachable — so the two are one value the callers cannot forget to set.
  struct Notice: Equatable, Sendable {
    /// Which of the three things happened. Closed, so a fourth cannot borrow another's sentence.
    enum Kind: Equatable, Sendable, CaseIterable {
      /// The spelling was written onto `word`.
      case saved
      /// `word` already carried the spelling, so nothing was written.
      case nothingToAdd
      /// `word` was created and there was no spelling to attach, because the panel opened without
      /// a readable selection. `spelling` is empty here.
      case created
      /// `word` was already in the library and there was no spelling to attach — the same state as
      /// `created`, arriving at a canonical that already existed. `spelling` is empty here.
      case alreadyInWords
    }

    let kind: Kind
    /// What the user selected. Empty for `.created`.
    let spelling: String
    /// The library word, as it is NOW — never the ranking's snapshot of it.
    let word: String
    /// Whether the invocation is still LIVE behind the notice: the search field is shown, typing
    /// returns to the full list, and nothing has been resolved yet.
    let searchable: Bool
  }

  private(set) var stage: Stage = .picking

  /// The correct spelling the user is typing, while composing. Separate from `query` on purpose:
  /// one navigates and the other is written, and a single field serving both is how a search string
  /// becomes a stored word.
  private(set) var draftCanonical: String = ""

  private let rankHeard: (String) -> QuickAddRanker.Ranking
  private let searchLibrary: (String, String) -> QuickAddRanker.Ranking

  init(
    heard: String,
    refusal: SelectionReader.Refusal? = nil,
    rankHeard: @escaping (String) -> QuickAddRanker.Ranking,
    searchLibrary: @escaping (String, String) -> QuickAddRanker.Ranking
  ) {
    self.heard = heard
    self.refusal = refusal
    self.rankHeard = rankHeard
    self.searchLibrary = searchLibrary
    // A refusal has no heard string to rank, so the panel opens on an empty list and a stated
    // reason rather than on a ranking of nothing.
    self.ranking = refusal == nil ? rankHeard(heard) : .empty
    // **Opened onto a word that is already covered, the panel says so and leaves (#2391 §3).**
    // The header already said `nothing to add` and the rest of the panel contradicted it: a
    // highlighted row whose only action is a no-op, four unrelated words offered as if they were
    // choices, a legend advertising `add spelling` in a state where nothing can be added, and a
    // dismissal the user had to perform by hand.
    //
    // Decided HERE rather than in the view, because it is not a rendering question: it changes what
    // Return does, whether the create row is offered, and whether this invocation resolves as
    // `already_saved` or as a cancel.
    if let top = self.ranking.preselected, top.alreadyHasHeardSpelling {
      self.stage = .notice(
        Notice(
          kind: .nothingToAdd, spelling: heard, word: top.word.canonical, searchable: true))
    }
  }

  // MARK: - The search field

  /// Re-rank for what the user has typed.
  ///
  /// Clearing the field restores the HEARD ranking, including its confidence-based preselection —
  /// not an empty list, and not the last search's results.
  func updateQuery(_ newQuery: String) {
    query = newQuery
    // A refusal describes the LAST accept. Typing is the user moving on from it.
    writeFailure = nil
    // **Typing is how the user says the notice was wrong about them.** A word already covered is
    // not the same as a user with nothing to do: the ranking can be wrong, and the search field is
    // the escape hatch built for exactly that. Reaching for it returns the full list and, because
    // the invocation has not resolved, cancels the pending auto-dismiss at its own guard.
    if case .notice(let notice) = stage, notice.searchable,
      !newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      stage = .picking
    }
    guard refusal == nil else { return }
    let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    ranking =
      trimmed.isEmpty
      ? rankHeard(heard)
      : searchLibrary(newQuery, heard)
  }

  // MARK: - Composing a new word

  /// The user asked to author a word by hand.
  ///
  /// **Seeded from the search field when they were searching, and empty otherwise.** Someone who
  /// typed a word, found nothing, and reached for Create has already told us what they mean; making
  /// them type it a second time is the panel forgetting. Someone who typed nothing gets an empty
  /// field rather than the misspelling they selected, because the misspelling is precisely what the
  /// new word must NOT be called.
  func beginComposing() {
    guard stage == .picking else { return }
    // A refusal describes the LAST accept, and composing is the user moving on from it — the same
    // rule `updateQuery` follows for the same reason.
    writeFailure = nil
    draftCanonical = isSearching ? query.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    stage = .composing
  }

  func updateDraft(_ newDraft: String) {
    draftCanonical = newDraft
    writeFailure = nil
  }

  /// Back to the list. Escape's meaning while composing.
  func cancelComposing() {
    guard stage == .composing else { return }
    stage = .picking
    draftCanonical = ""
    writeFailure = nil
  }

  /// Whether Escape belongs to the panel's CONTENT rather than to the window.
  ///
  /// **The one keypress with two meanings, and the window cannot tell them apart.** Escape is
  /// handled on the panel itself (`KeyCapablePanel.cancelOperation`) because a focused text field's
  /// field editor claims it first — so the window is where it arrives, and the window knows nothing
  /// about stages. Asking here keeps the rule in the one place that already owns every other
  /// keyboard decision, and it means a future stage cannot silently inherit "Escape closes
  /// everything" by not being thought about.
  ///
  /// - Returns: true when this consumed the keypress, so the panel must NOT dismiss.
  func consumeCancel() -> Bool {
    guard stage == .composing else { return false }
    cancelComposing()
    return true
  }

  /// The word the user has authored, or nil when there is nothing to create.
  ///
  /// **Returns the WORD rather than a Bool, so the caller cannot build a different one.** A
  /// `canCreate` flag plus a caller assembling `CustomWord(canonical: draft, aliases: [heard])` is
  /// two places that must agree about trimming and about whether an empty heard spelling becomes a
  /// blank alias — and the blank-alias case is exactly the one that made
  /// `QuickAddWiring.newWordOutcome`'s postcondition vacuous.
  ///
  /// The heard spelling rides as the first alias, which is the entire point of authoring the word
  /// from here rather than from Settings. With no readable selection there is no spelling, and the
  /// word is created carrying none rather than carrying one blank one.
  var draftWord: CustomWord? {
    let canonical = draftCanonical.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !canonical.isEmpty else { return nil }
    let spelling = heard.trimmingCharacters(in: .whitespacesAndNewlines)
    // A spelling identical to the canonical is not a mishearing, it is the word. Storing it as an
    // alias of itself is a duplicate the library would carry forever.
    let aliases =
      spelling.isEmpty || spelling.caseInsensitiveCompare(canonical) == .orderedSame
      ? [] : [spelling]
    return CustomWord(canonical: canonical, aliases: aliases)
  }

  // MARK: - The keyboard contract

  /// Move the highlight without leaving the search field.
  ///
  /// Clamped rather than wrapping: wrapping from the last row to the first is a surprise when the
  /// list is short and the user is holding the key, and this list is at most a handful of rows.
  func moveHighlight(by offset: Int) {
    // **An arrow press past a searchable notice means the same thing typing does: show me the
    // options.** The field is on screen and focused there, so both keys are available and only one
    // of them answered — pressing Down and watching nothing happen is the panel ignoring a key it
    // is visibly offering.
    if isShowingSearchableNotice { stage = .picking }
    guard !ranking.candidates.isEmpty else { return }
    let current = ranking.candidates.firstIndex { $0.id == ranking.preselectedID }
    // No highlight yet means the bar was not cleared, so an arrow press is the user OPTING IN to a
    // row. Down starts at the top; up starts at the bottom.
    let next: Int
    if let current {
      next = min(max(current + offset, 0), ranking.candidates.count - 1)
    } else {
      next = offset >= 0 ? 0 : ranking.candidates.count - 1
    }
    ranking = QuickAddRanker.Ranking(
      candidates: ranking.candidates, preselectedID: ranking.candidates[next].id)
  }

  /// Whether the user is actually filtering, as opposed to having pressed the space bar.
  ///
  /// **`!query.isEmpty` was the test at four call sites and it is wrong for whitespace.**
  /// `updateQuery` trims before deciding whether to re-rank — correctly, since a field holding two
  /// spaces should show the heard ranking rather than an empty filter — but it stores the RAW text,
  /// because that is what the field renders. So a whitespace-only field restored the heard ranking
  /// while every downstream reader still believed a search was in progress: the group header
  /// switched to its searching sentence under a user who had typed nothing, and `used_search=true`
  /// went out on the resulting accept, which is a telemetry claim that the ranking needed rescuing
  /// when it did not.
  ///
  /// One owner, derived, rather than four call sites each remembering to trim.
  var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// The row Return would accept, or nil when Return must write nothing.
  ///
  /// **nil while composing, and that is not defensive tidiness.** The list is still ranked and still
  /// carries a preselected row; only the view has stopped showing it. A legend derived from this
  /// would advertise `add spelling` over a compose field, and a stray Return arriving from anywhere
  /// but that field would write to a row the user can no longer see.
  var acceptTarget: QuickAddRanker.Candidate? {
    guard stage == .picking else { return nil }
    return ranking.preselected
  }

  /// Record that the library refused the write. Set by the coordinator's caller, never here: the
  /// model does not know what a words file is and must not learn.
  func noteWriteFailure(_ message: String) { writeFailure = message }

  /// Return has been pressed and something happened. Say what, then the caller takes the panel away.
  ///
  /// **`searchable` is set HERE rather than taken as an argument, and it is always false.** This is
  /// reached only after Return, when the user is already back in their sentence — a terminal notice
  /// offering a focused field is the exact keystroke-eating defect that nearly sent the confirmation
  /// to the dictation overlay instead of the panel. A caller that could pass `true` is a caller that
  /// can reintroduce it.
  func showNotice(_ kind: Notice.Kind, spelling: String, word: String) {
    writeFailure = nil
    stage = .notice(Notice(kind: kind, spelling: spelling, word: word, searchable: false))
  }

  /// Whether the panel is showing a notice the user can still type past.
  ///
  /// Read by the auto-dismiss before it resolves this invocation: the user may have typed in the
  /// meantime, which puts the panel back on its list and makes the invocation live again.
  var isShowingSearchableNotice: Bool {
    if case .notice(let notice) = stage { return notice.searchable }
    return false
  }

  /// Whether the search field belongs on screen.
  ///
  /// **A refusal hides it, and the copy depends on that.** `updateQuery` will not re-rank without a
  /// heard string, so under a refusal the field can be typed into and answers nothing. The refusal
  /// messages were rewritten precisely to stop pointing at it, and `noRefusalPointsAtTheSearchField`
  /// guards that wording — a disabled field left on screen is the control those messages were
  /// forbidden from naming, still sitting there.
  ///
  /// A searchable notice shows it, because typing past that notice is the whole reason it is a
  /// notice rather than a dismissal.
  var showsSearchField: Bool {
    (stage == .picking && refusal == nil) || isShowingSearchableNotice
  }

  /// The notice currently on screen, or nil. One accessor, so the view and the timer cannot disagree
  /// about which stage counts as a notice.
  var notice: Notice? {
    if case .notice(let notice) = stage { return notice }
    return nil
  }

  /// What gets written if the user accepts. **Always the original selection, never the query.**
  ///
  /// The distinction is the whole safety property of the search field: accepting a searched-for row
  /// must save what the user SELECTED, not what they typed to find it. Without this the escape
  /// hatch built to recover from a wrong ranking becomes a way to write an arbitrary string.
  var spellingToWrite: String { heard }
}
