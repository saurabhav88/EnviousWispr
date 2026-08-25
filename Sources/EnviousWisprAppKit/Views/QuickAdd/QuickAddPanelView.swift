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
  /// Create a new word carrying the heard spelling as its first alias.
  let onCreateNew: () -> Void
  /// Escape, or anything else that means "never mind".
  let onCancel: () -> Void

  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      searchWell
      if let refusal = model.refusal {
        Text(QuickAddPanelCopy.refusalMessage(refusal))
          .font(.stBody)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 16)
          .padding(.top, 14)
      }
      if let failure = model.writeFailure {
        Text(QuickAddPanelCopy.writeFailure(failure))
          .font(.stBody)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 16)
          .padding(.top, 14)
      }
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
      Divider().overlay(Color.stDivider).padding(.top, 10)
      createNewRow
      legend
    }
    .frame(width: 360)
    // The field takes focus on open, so typing is always the immediate alternative to accepting —
    // which is what makes a wrong-but-confident ranking recoverable without reaching for the mouse.
    .onAppear { searchFocused = true }
    // NO `.onExitCommand`. It sat here and never fired: the search field takes focus on open and its
    // field editor claims `cancelOperation(_:)` first. Escape is handled on the panel itself, where
    // nothing can intercept it — and leaving it here as well would give one keypress two dismissal
    // paths, which the coordinator's double-resolution guard would then report as a defect.
  }

  /// Which sentence the group header is saying. Derived, never stored: a second copy of this on the
  /// model is a second thing to keep in step with the ranking.
  var headerState: QuickAddPanelCopy.GroupHeaderState {
    if model.ranking.preselected?.alreadyHasHeardSpelling == true { return .alreadySaved }
    if !model.query.isEmpty { return .searching }
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
      if model.acceptTarget != nil {
        legendItem("\u{23CE}", QuickAddPanelCopy.legendAccept)
      }
      if !model.ranking.candidates.isEmpty {
        legendItem("\u{2191}\u{2193}", QuickAddPanelCopy.legendMove)
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
      Button(action: onCancel) { legendItem("esc", QuickAddPanelCopy.legendClose) }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(QuickAddPanelCopy.legendClose)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .background(Color.stSectionBg)
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
