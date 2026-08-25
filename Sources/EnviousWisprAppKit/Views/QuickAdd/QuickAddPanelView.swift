import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import SwiftUI

/// The Quick Add panel's copy, frozen.
///
/// A named table rather than strings inline in the view, so the founder-approved wording from the
/// 2026-08-24 design review can be asserted without rendering anything. Every separator here is a
/// MIDDLE DOT, never a dash.
enum QuickAddPanelCopy {
  static let searchPlaceholder = "Search your words"
  static let createNewWord = "Create a new word"

  /// The compose stage's one instruction, and the only place the panel names what it is about to
  /// create.
  ///
  /// **Two sentences because there are two situations, not because one needed softening.** With a
  /// readable selection the user is correcting a specific mishearing and the field means "what
  /// should this have been". With no selection there is nothing to correct — Create is then the
  /// panel's ONLY working control — and a header quoting an empty string would read as a bug.
  static func composeHeader(heard: String) -> String {
    heard.isEmpty ? "New word" : "Correct spelling for \"\(heard)\""
  }

  /// What the compose field says when empty. Names the thing to type, never the action.
  static func composePlaceholder(heard: String) -> String {
    heard.isEmpty ? "The word to add" : "The correct spelling"
  }

  /// The confirmation shown for a beat after Return (#2391 §1).
  ///
  /// **States what happened to the LIBRARY and promises nothing about future behaviour.** Not
  /// "saved", which says nothing about where; not "will be corrected from now on", which is a
  /// sentence the code cannot back — a spelling belongs to ONE word, and whether a future dictation
  /// reaches this one depends on the rest of the library.
  ///
  /// The asymmetry this closes: a refused write already kept the panel open and stated the reason,
  /// so the user learned more from failing than from succeeding, on a feature whose whole promise is
  /// that succeeding is invisible.
  static func savedNotice(spelling: String, word: String) -> String {
    "\"\(spelling)\" added to \(word)"
  }

  /// The word already carries this spelling, so there is nothing to add (#2391 §3).
  ///
  /// Names the WORD first, because that is the fact the user does not have: they know what they
  /// selected and are asking who owns it.
  static func nothingToAddNotice(spelling: String, word: String) -> String {
    "\(word) already knows \"\(spelling)\""
  }

  /// A word authored by hand with no spelling to attach, which is the state Create exists for: the
  /// panel opened without a readable selection, so there is no mishearing to name.
  static func createdNotice(word: String) -> String {
    "\(word) added to your words"
  }

  /// The user authored a word by hand that was already in the library, with no spelling to attach.
  ///
  /// **Not a refusal, and it used to be one.** The panel that reaches this opened WITHOUT a readable
  /// selection, so its ranking is empty and its search field is not on screen — and the refusal's
  /// copy told the user to choose the word from a list that cannot exist there. Nothing is wrong
  /// in this state: they asked for the word to be in their words, and it is.
  static func alreadyInWordsNotice(word: String) -> String {
    "\(word) is already in your words"
  }

  /// The one place a `Notice` becomes English.
  ///
  /// **Exhaustive over `Kind` on purpose.** The model carries the FACTS — which thing happened, to
  /// which word, with which spelling — and never a sentence, so a new outcome cannot ship borrowing
  /// another's wording by being handed a string at the call site. A `switch` here is what makes the
  /// compiler ask.
  static func notice(_ notice: QuickAddPanelModel.Notice) -> String {
    switch notice.kind {
    case .saved: savedNotice(spelling: notice.spelling, word: notice.word)
    case .nothingToAdd: nothingToAddNotice(spelling: notice.spelling, word: notice.word)
    case .created: createdNotice(word: notice.word)
    case .alreadyInWords: alreadyInWordsNotice(word: notice.word)
    }
  }

  /// Shown when the library refused the write, above the rows so the panel that stayed open says
  /// why. The message comes from the words authority itself rather than being reworded here: it is
  /// the same sentence the editor shows for the same refusal, and a second wording would be a
  /// second set of rules for the user to reconcile.
  static func writeFailure(_ message: String) -> String { "Not saved. \(message)" }

  /// The edit sheet saved and the word is not in the library afterwards. Rare, and deliberately not
  /// specific: the reasons `CustomWordsManager.add` can return silently are not distinguishable from
  /// the caller, so naming one would be a guess presented as a fact.
  static let newWordNotSaved =
    "That word could not be saved. Check it does not already exist in your words."

  /// The row's word was in the library when the panel was ranked and is not there now, because the
  /// panel stays open and the user deleted it in Settings in between.
  ///
  /// **Written to sit UNDER `writeFailure`'s "Not saved." prefix**, which is the channel it travels
  /// through: `accept` returns it, the wiring hands it to `noteWriteFailure`, and the view renders
  /// that prefix. So it does not repeat "was not added" — reusing a refusal path means inheriting
  /// its sentence, and a copy written as though it stood alone reads as a stutter once rendered.
  static let wordNoLongerExists =
    "That word is no longer in your words. Create it as a new word instead."

  /// The canonical already existed, so the library kept what it had and the spelling was not added.
  /// Names the surviving word, because the way forward is to pick it from the list.
  static func newWordAlreadyExists(canonical: String) -> String {
    "\"\(canonical)\" already exists and was left as it is. Choose it from the list instead to "
      + "add this spelling."
  }

  /// The one line above the list, which is the sentence every row completes.
  ///
  /// **This is what buys the compactness.** The old design repeated "add as a new spelling" on every
  /// row, so five candidates cost ten lines and four of the five subtitles wrapped. The verb is
  /// stated ONCE here and the rows carry only a name and a count, which is five lines for the same
  /// five candidates.
  ///
  /// It is also the panel's confidence signal in words rather than in styling. Below the bar nothing
  /// is preselected, and a list that looks identical either way leaves the user to infer the
  /// difference from a missing tint.
  static func groupHeader(_ state: GroupHeaderState, heard: String) -> String {
    switch state {
    case .confident: "Add \"\(heard)\" to"
    case .lowConfidence: "No close match · pick one or keep typing"
    case .alreadySaved: "Already knows \"\(heard)\" · nothing to add"
    case .searching: "Add \"\(heard)\" to"
    }
  }

  /// What the list is currently saying. Four cases, closed, so a new one forces every consumer to
  /// say what it does with it rather than falling into whichever branch is nearest.
  enum GroupHeaderState: Equatable, Sendable, CaseIterable {
    /// A row is preselected: the bar was cleared and Return will write.
    case confident
    /// Rows exist and none is preselected. Return writes nothing, deliberately.
    case lowConfidence
    /// The top match already carries this spelling, so there is nothing to add.
    case alreadySaved
    /// The user is filtering. Same verb as `confident`; the header must not change under them
    /// mid-keystroke, which is the one thing a header that also carries state can get wrong.
    case searching
  }

  /// The right-hand meta on a row. A count, not a sentence.
  static func spellingCount(_ count: Int) -> String {
    "\(count) \(count == 1 ? "spelling" : "spellings")"
  }

  /// The meta on a row that already carries the heard spelling, in place of the count.
  ///
  /// **The row promised an add it could not make.** `QuickAddRanker.Candidate` has carried
  /// `alreadyHasHeardSpelling` since the first chunk and the coordinator branches on it — accepting
  /// such a row writes NOTHING and resolves `alreadySaved` — but the view never read the flag, so
  /// every row said "add as a new spelling", the user pressed Return, and the panel closed having
  /// done nothing and said nothing. Reachable on the first thing anyone tries: a word corrected once
  /// scores 1.00 and lands here.
  static let alreadyHasThisSpelling = "already has this"

  /// The keyboard legend along the bottom.
  ///
  /// Not chrome. It is the contract made visible, and it is the cheapest teaching surface a feature
  /// whose whole value is keyboard speed can have. Its CONTENTS are derived rather than fixed: if
  /// Return does nothing in this state, Return is not listed, so the legend can never promise a key
  /// that will not answer.
  static let legendAccept = "add spelling"
  static let legendMove = "move"
  static let legendClose = "close"

  /// The compose stage's two caps. `back` and not `close`, because Escape means something different
  /// there — the legend is the contract made visible, and a legend that says `close` over a field
  /// whose Escape returns to the list is the panel promising a key it will not answer.
  static let legendCreate = "create"
  static let legendBack = "back"

  /// The one line shown instead of a ranking when we could not read a selection.
  ///
  /// Every refusal gets its own sentence. A single "could not read your selection" would be
  /// technically true for all of them and useless for the only one the user can act on.
  ///
  /// **Every sentence points at a control that actually works in this state, and three of them
  /// used to point at one that does not.** With no heard spelling there is nothing to rank and
  /// nothing to add a spelling TO, so `QuickAddPanelModel.updateQuery` deliberately does not
  /// re-rank and the view hides the field — and the earlier wording, "You can search for the word
  /// below", sent the user to a field that would not have answered. The one thing that does work
  /// here is authoring the word by hand, which is the row below the divider.
  static func refusalMessage(_ refusal: SelectionReader.Refusal) -> String {
    switch refusal {
    case .accessibilityNotTrusted:
      "EnviousWispr needs Accessibility permission to read your selection. Turn it on in System "
        + "Settings, then try again."
    case .noFrontmostApplication:
      "No app was in front, so there was nothing to read."
    case .noFocusedElement:
      "That app did not tell us where the cursor is. Click into the text and try again."
    case .selectionUnsupported:
      "That app does not share its selection with other apps. You can still add the word by hand "
        + "below."
    case .selectionUnavailable:
      "That app reports a selection it will not share. Terminals do this. You can still add the "
        + "word by hand below."
    case .unreadable:
      "Your selection could not be read. You can still add the word by hand below."
    case .selectionTooLong:
      "That selection is too long to be a word. Select just the word and try again."
    case .wordsUnavailable:
      // The plan's exact wording (§3, "Refresh before ranking"). Capital W on Words because that is
      // what the feature is called in Settings, and a user reading this has to find it there.
      "Your Words could not be refreshed, so there is nothing to match against yet. Try again."
    case .nothingSelected:
      // The likeliest refusal of the eight, and the only one where NOTHING went wrong. It used to
      // borrow `selectionUnavailable`'s sentence, which names terminals and blames the frontmost
      // app — a confident diagnosis handed to someone whose only mistake was not highlighting a
      // word. So this one names no app, assigns no fault, and says the single thing that fixes it.
      // No route named ("press the shortcut again"), because BOTH doors reach here: the hotkey with
      // nothing highlighted, and the Services menu handed whitespace. A sentence naming one of them
      // is wrong half the time it is shown.
      "Nothing was selected. Highlight the word you want and try again, or add it by hand below."
    }
  }
}

/// Renders the Quick Add panel and owns its key handling (#2381).
///
/// **Rendering and keys, nothing else.** No ranking, no word library, no window: the model beside it
/// decides which row Return accepts, and the coordinator above it decides what happens when it does.
struct QuickAddPanelView: View {

  @Bindable var model: QuickAddPanelModel

  /// Accept a candidate: add the heard spelling to that word.
  let onAccept: (QuickAddRanker.Candidate) -> Void
  /// Move to the compose stage. The word itself is built by the model, not here.
  let onCreateNew: () -> Void
  /// Commit the authored word. Handed the word rather than the typed text, so the view cannot
  /// assemble a different one than the model validated.
  let onCreate: (CustomWord) -> Void
  /// Escape, or anything else that means "never mind".
  let onCancel: () -> Void

  @FocusState private var searchFocused: Bool
  @FocusState private var composeFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // **Hoisted out of the stages, and that is structural rather than cosmetic.** A searchable
      // notice shows the field too, and typing in it returns the panel to its list — so a field
      // rendered inside each branch would be a DIFFERENT view to SwiftUI on either side of that
      // transition. It would be torn down and rebuilt at the exact keystroke that causes the
      // transition, losing focus and the character that triggered it.
      if model.showsSearchField { searchWell }
      switch model.stage {
      case .picking: pickingContent
      case .composing: composingContent
      case .notice(let notice): noticeContent(notice)
      }
      Divider().overlay(Color.stDivider).padding(.top, 10)
      if model.stage == .picking { createNewRow }
      legend
    }
    .frame(width: 360)
    // NO `.onExitCommand`. It sat here and never fired: the search field takes focus on open and its
    // field editor claims `cancelOperation(_:)` first. Escape is handled on the panel itself, where
    // nothing can intercept it — and leaving it here as well would give one keypress two dismissal
    // paths, which the coordinator's double-resolution guard would then report as a defect.
    //
    // Escape now has TWO meanings and the window still cannot tell them apart, which is why the
    // decision stayed on the model (`consumeCancel`) rather than moving back here.
  }

  /// The ranked list, and the refusal or failure above it.
  @ViewBuilder
  private var pickingContent: some View {
    if let refusal = model.refusal {
      Text(QuickAddPanelCopy.refusalMessage(refusal))
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }
    failureBanner
    if !model.ranking.candidates.isEmpty {
      Text(QuickAddPanelCopy.groupHeader(headerState, heard: model.heard))
        .font(.stSectionHeader)
        .tracking(0.5)
        .foregroundStyle(headerState == .lowConfidence ? .stTextTertiary : .stAccent)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
      candidateRows
    }
  }

  /// One field, and the sentence saying what it is for.
  ///
  /// **No category, no strictness, no AI suggestions, no delete.** Those are a Settings affordance
  /// for someone curating a library; this is someone who highlighted a misspelling two seconds ago.
  /// All three take their defaults and are editable in Settings afterwards, which is stated here
  /// rather than in a commit nobody will read.
  @ViewBuilder
  private var composingContent: some View {
    Text(QuickAddPanelCopy.composeHeader(heard: model.heard))
      .font(.stSectionHeader)
      .tracking(0.5)
      .foregroundStyle(.stAccent)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 16)
      .padding(.top, 14)
      .padding(.bottom, 6)
    composeWell
    failureBanner
  }

  /// The panel with nothing left to ask: one sentence, and then it takes itself away.
  ///
  /// **Three lines where the shipped panel rendered nine.** Opened onto a word already covered, the
  /// header said `nothing to add` and the rest of the panel contradicted it — a highlighted row
  /// whose only action was a no-op, four unrelated words offered as if they were choices, and a
  /// legend advertising a verb the state could not perform.
  ///
  /// The search field above this stays for a searchable notice, because the ranking can be wrong
  /// and typing is how the user says so.
  @ViewBuilder
  private func noticeContent(_ notice: QuickAddPanelModel.Notice) -> some View {
    let message = QuickAddPanelCopy.notice(notice)
    Text(message)
      .font(.stBody)
      .foregroundStyle(.stTextPrimary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 16)
      .padding(.top, 14)
      .accessibilityLabel(message)
  }

  /// Why the last write did not happen. Shared by both stages: the library refuses through the same
  /// channel whichever field the user was in, and a second banner would be a second wording.
  @ViewBuilder
  private var failureBanner: some View {
    if let failure = model.writeFailure {
      Text(QuickAddPanelCopy.writeFailure(failure))
        .font(.stBody)
        .foregroundStyle(.stError)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }
  }

  private var composeWell: some View {
    HStack(spacing: 8) {
      Image(systemName: "plus")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.stTextTertiary)
      TextField(
        QuickAddPanelCopy.composePlaceholder(heard: model.heard),
        // Explicit closures, NOT a bare method reference — see the note on `searchWell`. Swift
        // 6.3.3 crashes emitting the reabstraction thunk, with no source diagnostic.
        text: Binding(get: { model.draftCanonical }, set: { model.updateDraft($0) })
      )
      .textFieldStyle(.plain)
      .font(.system(size: 15))
      .foregroundStyle(.stTextPrimary)
      .focused($composeFocused)
      // **Return creates only when there is something to create.** An empty field does nothing,
      // which is the same rule the picking stage applies below the confidence bar, and the legend
      // says so by omitting the cap.
      .onSubmit {
        guard let word = model.draftWord else { return }
        onCreate(word)
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 38)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.stSectionBg))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(composeFocused ? Color.stAccentSolid : Color.stDivider, lineWidth: 1)
    )
    .padding(.horizontal, 12)
    .padding(.top, 2)
    // The field takes focus the moment the stage appears. Without it the user reaches Create and
    // types into nothing — and the panel is key-capable precisely so that cannot happen.
    .onAppear { composeFocused = true }
  }

  /// Which sentence the group header is saying. Derived, never stored: a second copy of this on the
  /// model is a second thing to keep in step with the ranking.
  var headerState: QuickAddPanelCopy.GroupHeaderState {
    if model.ranking.preselected?.alreadyHasHeardSpelling == true { return .alreadySaved }
    if model.isSearching { return .searching }
    return model.ranking.preselectedID == nil ? .lowConfidence : .confident
  }

  // MARK: - Regions

  /// The search field, and the reason it is a WELL rather than a strip.
  ///
  /// **It was already the widest, topmost element and still did not read as typable.** The old one
  /// was a full-bleed strip on a panel made of full-bleed strips, so nothing distinguished it from a
  /// title area — and size could not fix that, because size was never the variable. A field is
  /// recognised by its EDGES: a border, a recessed fill, a radius, a caret, and the magnifier that
  /// makes Spotlight unmistakable at a glance.
  ///
  /// The selected word used to ride in here as a pill, which occupied exactly the slot the magnifier
  /// needs. Moving it to the group header is what made room for the one glyph that does the work,
  /// and it retired the only genuinely fiddly piece of SwiftUI in the design.
  private var searchWell: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.stTextTertiary)
      TextField(
        QuickAddPanelCopy.searchPlaceholder,
        // `set: { model.updateQuery($0) }`, NOT `set: model.updateQuery`. The bare method reference
        // makes the compiler build a reabstraction thunk from a `@MainActor` method to `Binding`'s
        // non-isolated setter, and Swift 6.3.3 CRASHES emitting it — swift-frontend aborts in IR
        // generation with no source diagnostic, so the build fails with zero `error:` lines and names
        // only this file. The explicit closure is the same behaviour and compiles. Do not tidy it back.
        text: Binding(get: { model.query }, set: { model.updateQuery($0) })
      )
      .textFieldStyle(.plain)
      .font(.system(size: 15))
      .foregroundStyle(.stTextPrimary)
      .focused($searchFocused)
      // Unreachable today — `showsSearchField` hides the field under a refusal — and kept as the
      // floor: any future state that shows the field without a rankable heard string gets an inert
      // control rather than a silent one.
      .disabled(model.refusal != nil)
      // Arrows move the highlight WITHOUT leaving the field, which is what lets the user keep typing
      // after correcting the selection.
      .onMoveCommand { direction in
        switch direction {
        case .down: model.moveHighlight(by: 1)
        case .up: model.moveHighlight(by: -1)
        default: break
        }
      }
      // **Return writes only when a highlighted row exists.** Below the confidence bar, and on zero
      // results, there is no highlight and this does nothing — which is the bar doing its job rather
      // than a dead key.
      .onSubmit {
        guard let target = model.acceptTarget else { return }
        onAccept(target)
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 38)
    .background(
      RoundedRectangle(cornerRadius: 8).fill(Color.stSectionBg)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(searchFocused ? Color.stAccentSolid : Color.stDivider, lineWidth: 1)
    )
    .padding(.horizontal, 12)
    .padding(.top, 12)
    // The field takes focus when the stage appears, so typing is always the immediate alternative
    // to accepting — which is what makes a wrong-but-confident ranking recoverable without reaching
    // for the mouse. Moved off the body when the body gained a second stage: left there it fired
    // once, at open, and returning from Compose left the panel with no focused field at all.
    .onAppear { searchFocused = true }
  }

  private var candidateRows: some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(model.ranking.candidates) { candidate in
        row(for: candidate, isHighlighted: candidate.id == model.ranking.preselectedID)
      }
    }
  }

  /// One row: a name, and a count. No verb.
  ///
  /// The verb lives in the group header, said once. That is the whole reason five candidates fit in
  /// five lines rather than the ten that a wrapped per-row subtitle costs.
  private func row(for candidate: QuickAddRanker.Candidate, isHighlighted: Bool) -> some View {
    Button {
      onAccept(candidate)
    } label: {
      HStack(spacing: 10) {
        Text(candidate.word.canonical)
          .font(.stRowLabel)
          .foregroundStyle(.stTextPrimary)
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(
          candidate.alreadyHasHeardSpelling
            ? QuickAddPanelCopy.alreadyHasThisSpelling
            : QuickAddPanelCopy.spellingCount(candidate.word.aliases.count)
        )
        .font(.stHelper)
        .foregroundStyle(.stTextTertiary)
        .lineLimit(1)
        if isHighlighted {
          Text("\u{23CE}")
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
        }
      }
      .padding(.vertical, 7)
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isHighlighted ? Color.stAccent.opacity(0.14) : .clear)
      .clipShape(RoundedRectangle(cornerRadius: 6))
      // A row that cannot add anything is shown, because hiding it would answer "is this word
      // already handled" by saying nothing, but it is visibly not the live option.
      .opacity(candidate.alreadyHasHeardSpelling ? 0.55 : 1)
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .accessibilityLabel(Self.accessibilityLabel(for: candidate))
    .padding(.horizontal, 6)
  }

  /// One owner for what a row says about itself, read by the accessibility label and derived from
  /// the same two strings the visible row uses. Two call sites computing this independently is how
  /// they came to disagree elsewhere.
  static func accessibilityLabel(for candidate: QuickAddRanker.Candidate) -> String {
    let meta =
      candidate.alreadyHasHeardSpelling
      ? QuickAddPanelCopy.alreadyHasThisSpelling
      : QuickAddPanelCopy.spellingCount(candidate.word.aliases.count)
    return "\(candidate.word.canonical), \(meta)"
  }

  /// The keyboard contract, made visible.
  ///
  /// **Its contents are derived, so it can never promise a key that will not answer.** The Return
  /// cap appears only when a row is actually preselected — below the confidence bar it is absent,
  /// which is the same fact the group header states in words. It also teaches arrow navigation to a
  /// user who would otherwise have to discover it by accident.
  private var legend: some View {
    HStack(spacing: 14) {
      // Switched on the stage rather than tested for one, so a new stage cannot inherit whichever
      // branch happens to be the `else`. A notice offers no keys of its own: the ranking behind it
      // still HAS a preselected row, and an `↑↓ move` cap over a sentence would name a control that
      // is not on screen.
      switch model.stage {
      case .composing:
        if model.draftWord != nil {
          legendItem("\u{23CE}", QuickAddPanelCopy.legendCreate)
        }
      case .picking:
        if model.acceptTarget != nil {
          legendItem("\u{23CE}", QuickAddPanelCopy.legendAccept)
        }
        if !model.ranking.candidates.isEmpty {
          legendItem("\u{2191}\u{2193}", QuickAddPanelCopy.legendMove)
        }
      case .notice:
        EmptyView()
      }
      // **A BUTTON, and it is the only mouse path off this panel.** The standard close control is
      // hidden because `.fullSizeContentView` puts the hosting view over the titlebar, so unhiding
      // it produces nothing — measured. And `windowDidResignKey` is deliberately a no-op now, so
      // clicking away no longer dismisses either. That left Escape as the sole exit, which is
      // exactly the founder's original complaint arriving through a different door: a keyboard-only
      // way out is invisible to anyone who does not already know it, and unusable for anyone who
      // cannot reach that key.
      //
      // The legend is where it belongs rather than in new chrome: it already names this key, so a
      // user reading "esc close" and clicking it is doing the obvious thing.
      // Escape's label and its action both follow the stage, from ONE derived value. Two
      // independent `if`s here is how a button comes to say `back` and dismiss the panel.
      Button(action: escapeAction) { legendItem("esc", escapeLabel) }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(escapeLabel)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .background(Color.stSectionBg)
  }

  /// What Escape says, and what it does. Derived together so they cannot disagree.
  private var escapeLabel: String {
    model.stage == .composing ? QuickAddPanelCopy.legendBack : QuickAddPanelCopy.legendClose
  }

  /// **Asks the model the same question the WINDOW asks.** Escape arrives twice by two routes —
  /// `KeyCapablePanel.cancelOperation` for the key, this button for the mouse — and a second copy of
  /// the rule here is how the two came to mean different things in the compose stage.
  private func escapeAction() {
    guard !model.consumeCancel() else { return }
    onCancel()
  }

  private func legendItem(_ cap: String, _ label: String) -> some View {
    HStack(spacing: 5) {
      Text(cap)
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(.stTextSecondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
          RoundedRectangle(cornerRadius: 4).fill(Color.stDivider.opacity(0.5))
        )
      Text(label)
        .font(.stHelper)
        .foregroundStyle(.stTextTertiary)
    }
    .accessibilityElement(children: .combine)
  }

  private var createNewRow: some View {
    Button(action: onCreateNew) {
      HStack(spacing: 8) {
        Image(systemName: "plus")
        Text(QuickAddPanelCopy.createNewWord)
      }
      .font(.stRowLabel)
      .foregroundStyle(.stTextPrimary)
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .accessibilityLabel(QuickAddPanelCopy.createNewWord)
  }
}
