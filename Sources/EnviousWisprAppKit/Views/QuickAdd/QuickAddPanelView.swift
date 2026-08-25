import EnviousWisprPostProcessing
import EnviousWisprServices
import SwiftUI

/// The Quick Add panel's copy, frozen.
///
/// A named table rather than strings inline in the view, so the founder-approved wording from the
/// 2026-08-24 design review can be asserted without rendering anything. Every separator here is a
/// MIDDLE DOT, never a dash.
enum QuickAddPanelCopy {
  static let heardLabel = "Heard"
  static let searchPlaceholder = "Search your words"
  static let createNewWord = "Create a new word"
  static let returnHint = "Return"
  static let alreadySaved = "already saved"

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

  /// The subtitle under a candidate: what accepting it would do, then how much that word already
  /// carries. Singular matters — "1 spellings already saved" is the kind of thing users screenshot.
  static func rowSubtitle(spellingCount: Int) -> String {
    let noun = spellingCount == 1 ? "spelling" : "spellings"
    return "add as a new spelling · \(spellingCount) \(noun) \(alreadySaved)"
  }

  /// The subtitle for a word that ALREADY carries the heard spelling.
  ///
  /// **The row promised an add it could not make.** `QuickAddRanker.Candidate` has carried
  /// `alreadyHasHeardSpelling` since the first chunk and the coordinator branches on it — accepting
  /// such a row writes NOTHING and resolves `alreadySaved` — but the view never read the flag, so the
  /// row said "add as a new spelling", the user pressed Return, and the panel closed having done
  /// nothing and said nothing. Reported success, one file away from the code that refuses to report
  /// it, and reachable on the very first thing a user tries: any word they have already corrected
  /// once scores 1.00 and lands here.
  static func rowSubtitleAlreadyHas(spellingCount: Int) -> String {
    let noun = spellingCount == 1 ? "spelling" : "spellings"
    return "already has this spelling · \(spellingCount) \(noun) saved"
  }

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
    VStack(alignment: .leading, spacing: 14) {
      heardHeader
      // Hidden on a refusal rather than rendered dead. `updateQuery` does not re-rank without a
      // heard string — correctly, since there would be nothing to add a spelling to — so a field
      // shown here is a control the user can type into and watch do nothing.
      if model.refusal == nil { searchField }
      if let refusal = model.refusal {
        Text(QuickAddPanelCopy.refusalMessage(refusal))
          .font(.stBody)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let failure = model.writeFailure {
        Text(QuickAddPanelCopy.writeFailure(failure))
          .font(.stBody)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
      }
      candidateRows
      Divider().overlay(Color.stDivider)
      createNewRow
    }
    .padding(18)
    .frame(width: 360)
    // The field takes focus on open, so typing is always the immediate alternative to accepting —
    // which is what makes a wrong-but-confident ranking recoverable without reaching for the mouse.
    .onAppear { searchFocused = true }
    // NO `.onExitCommand`. It sat here and never fired: the search field takes focus on open and its
    // field editor claims `cancelOperation(_:)` first. Escape is handled on the panel itself, where
    // nothing can intercept it — and leaving it here as well would give one keypress two dismissal
    // paths, which the coordinator's double-resolution guard would then report as a defect.
  }

  // MARK: - Regions

  private var heardHeader: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(QuickAddPanelCopy.heardLabel)
        .font(.stSectionHeader)
        .tracking(0.6)
        .foregroundStyle(.stAccent)
      Text(model.heard)
        .font(.stRowTitle)
        .foregroundStyle(.stTextPrimary)
        .textSelection(.enabled)
    }
  }

  private var searchField: some View {
    TextField(
      QuickAddPanelCopy.searchPlaceholder,
      // `set: { model.updateQuery($0) }`, NOT `set: model.updateQuery`. The bare method reference
      // makes the compiler build a reabstraction thunk from a `@MainActor` method to `Binding`'s
      // non-isolated setter, and Swift 6.3.3 CRASHES emitting it — swift-frontend aborts in IR
      // generation with no source diagnostic, so the build fails with zero `error:` lines and names
      // only this file. The explicit closure is the same behaviour and compiles. Do not tidy it back.
      text: Binding(get: { model.query }, set: { model.updateQuery($0) })
    )
    .textFieldStyle(.roundedBorder)
    .focused($searchFocused)
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

  private var candidateRows: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(model.ranking.candidates) { candidate in
        row(for: candidate, isHighlighted: candidate.id == model.ranking.preselectedID)
      }
    }
  }

  private func row(for candidate: QuickAddRanker.Candidate, isHighlighted: Bool) -> some View {
    Button {
      onAccept(candidate)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(candidate.word.canonical)
            .font(.stRowLabel)
            .foregroundStyle(.stTextPrimary)
          Text(Self.subtitle(for: candidate))
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
        }
        Spacer(minLength: 8)
        if isHighlighted {
          Text(QuickAddPanelCopy.returnHint)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
        }
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(isHighlighted ? Color.stAccent.opacity(0.14) : .clear)
      .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .accessibilityLabel("\(candidate.word.canonical), \(Self.subtitle(for: candidate))")
  }

  /// One owner for what a row says about itself, read by the visible label AND the accessibility
  /// one. Two call sites computing this independently is how they came to disagree elsewhere.
  static func subtitle(for candidate: QuickAddRanker.Candidate) -> String {
    candidate.alreadyHasHeardSpelling
      ? QuickAddPanelCopy.rowSubtitleAlreadyHas(spellingCount: candidate.word.aliases.count)
      : QuickAddPanelCopy.rowSubtitle(spellingCount: candidate.word.aliases.count)
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
