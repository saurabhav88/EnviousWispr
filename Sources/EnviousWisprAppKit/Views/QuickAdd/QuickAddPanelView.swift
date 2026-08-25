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

  /// The subtitle under a candidate: what accepting it would do, then how much that word already
  /// carries. Singular matters — "1 spellings already saved" is the kind of thing users screenshot.
  static func rowSubtitle(spellingCount: Int) -> String {
    let noun = spellingCount == 1 ? "spelling" : "spellings"
    return "add as a new spelling · \(spellingCount) \(noun) \(alreadySaved)"
  }

  /// The one line shown instead of a ranking when we could not read a selection.
  ///
  /// Every refusal gets its own sentence. A single "could not read your selection" would be
  /// technically true for all of them and useless for the only one the user can act on.
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
      "That app does not share its selection with other apps. You can search for the word below."
    case .selectionUnavailable:
      "That app reports a selection it will not share. Terminals do this. You can search for the "
        + "word below."
    case .unreadable:
      "Your selection could not be read. You can search for the word below."
    case .selectionTooLong:
      "That selection is too long to be a word. Select just the word and try again."
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
      searchField
      if let refusal = model.refusal {
        Text(QuickAddPanelCopy.refusalMessage(refusal))
          .font(.stBody)
          .foregroundStyle(.stTextSecondary)
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
    .onExitCommand(perform: onCancel)
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
          Text(QuickAddPanelCopy.rowSubtitle(spellingCount: candidate.word.aliases.count))
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
    .accessibilityLabel(
      "\(candidate.word.canonical), \(QuickAddPanelCopy.rowSubtitle(spellingCount: candidate.word.aliases.count))"
    )
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
