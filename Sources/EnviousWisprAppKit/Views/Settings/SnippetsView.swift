import EnviousWisprCore
import SwiftUI

/// The Snippets page (#628), built to the approved Claude Design prototype
/// (`docs/feature-requests/issue-628-design/EnviousWispr Snippets.dc.html`).
///
/// Three cards: the keyword, the list, and — when the list is empty — the state that explains
/// what a snippet is for. Import (#2997) opens the review-then-commit sheet from the place the
/// design gives its button.
struct SnippetsView: View {
  @Environment(SnippetsCoordinator.self) private var coordinator

  @State private var query = ""
  /// ONE route for both sheets, so the two can never be presented at once: two independent
  /// `.sheet(item:)` states are not mutually exclusive, and macOS 14 behaviour with two
  /// presented sheets is unverified (plan §3.5).
  @State private var sheetRoute: SnippetsSheetRoute?
  @State private var keywordField = ""
  /// Held here rather than on the coordinator: an export never changes the store, so a failed
  /// one must not sit in the same slot as a failed save and read as though a snippet was lost.
  @State private var exportMessage: String?
  /// The keyword field commits on focus loss as well as on Return. Only `.onSubmit` meant a
  /// user could type a new keyword, click Add snippet, and be silently left on the old one,
  /// with nothing on screen saying Return was required.
  @FocusState private var keywordFocused: Bool

  var body: some View {
    SettingsContentView {
      keywordCard
      listCard
    }
    .onAppear { keywordField = coordinator.keyword }
    // A refresh from disk (an import's review, an export) can adopt a keyword another
    // EnviousWispr process changed; the field follows unless the user is typing in it, or
    // leaving the untouched field would write the old keyword back.
    .onChange(of: coordinator.keyword) { _, keyword in
      if !keywordFocused { keywordField = keyword }
    }
    .sheet(item: $sheetRoute) { route in
      switch route {
      case .edit(let draft):
        SnippetEditSheet(draft: draft, keyword: coordinator.keyword)
      case .importSnippets:
        // Closures, not the coordinator: the sheet reads the list FROM DISK at each
        // comparison so a stale rebuild sees what another process wrote, and commits
        // through the coordinator's one import writer.
        SnippetImportSheet(
          dependencies: .live(
            existingSnippets: { coordinator.refreshFromDisk().snippets },
            commit: { await coordinator.commitImport($0) }))
      }
    }
  }

  // MARK: - Keyword

  private var keywordCard: some View {
    BrandedPanel(
      icon: "mic",
      header: "Keyword",
      description:
        "A snippet only fires when you say this word first. Say the trigger on its own and your dictation is left alone."
    ) {
      HStack(spacing: 10) {
        Text("Say").settingsRowLabel()
        TextField("", text: $keywordField)
          .textFieldStyle(.roundedBorder)
          .frame(width: 190)
          .focused($keywordFocused)
          .onSubmit { commitKeyword() }
          .onChange(of: keywordFocused) { _, focused in
            if !focused { commitKeyword() }
          }
        Text("then your snippet, and it expands.").settingsHelperCopy()
        Spacer(minLength: 0)
      }
    } footnote: {
      keywordExample.settingsHelperCopy()
    }
  }

  /// The one concrete instruction on the screen: the rule is easy to state and easy to misread,
  /// and one sentence answers "so what do I actually say" faster than the description does.
  ///
  /// Built from a trigger the user ACTUALLY HAS, never from a literal. A hardcoded "my email"
  /// was true on a fresh install and became a lie the moment they renamed or deleted that
  /// starter: the screen would keep telling them to say words that fire nothing. With no
  /// snippets at all there is no honest example, so it names none.
  @ViewBuilder private var keywordExample: some View {
    if let trigger = coordinator.snippets.first?.trigger {
      Text(
        "For example, say \u{201C}\(coordinator.keyword) \(trigger)\u{201D} and that snippet is pasted."
      )
    } else {
      Text(
        "Say your keyword, then the words you saved a snippet under, and that snippet is pasted."
      )
    }
  }

  private func commitKeyword() {
    guard keywordField != coordinator.keyword else { return }
    _ = coordinator.setKeyword(keywordField)
    // Read back rather than keeping what was typed: a blank field becomes the default, so the
    // field must show what was actually saved, not what the user last had on screen.
    keywordField = coordinator.keyword
  }

  // MARK: - List

  private var listCard: some View {
    BrandedSection(header: "Your snippets") {
      VStack(alignment: .leading, spacing: 0) {
        header
        if coordinator.storeUnreadable {
          // NOT the empty state. An empty list is a lie the user would act on by adding
          // snippets over the top of ones that still exist.
          unreadableState
        } else if coordinator.snippets.isEmpty {
          emptyState
        } else {
          searchField
          Divider().overlay(Color.stDivider)
          rows
        }
      }
    } footer: {
      if let message = coordinator.errorMessage ?? exportMessage {
        Text(message)
          .font(.stHelper)
          .foregroundStyle(.stError)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text(countLabel).settingsHelperCopy()
      Spacer(minLength: 0)
      // Enabled even when the store is unreadable, like Export: the import itself then
      // refuses with the coordinator's own sentence rather than the button going dark.
      SettingsActionButton(
        title: "Import", isEnabled: true, emphasis: .outlined,
        systemImage: "square.and.arrow.down"
      ) {
        sheetRoute = .importSnippets
      }
      SettingsActionButton(
        title: "Export", isEnabled: !coordinator.snippets.isEmpty, emphasis: .outlined
      ) {
        let vocabulary = coordinator.vocabulary
        Task {
          exportMessage = SnippetsExportAction.message(
            for: await SnippetsExportAction.run(
              vocabulary: vocabulary,
              currentVocabulary: { coordinator.refreshFromDisk() }))
        }
      }
      SettingsActionButton(title: "Add snippet", isEnabled: true, emphasis: .filled) {
        sheetRoute = .edit(SnippetDraft(snippet: nil))
      }
    }
    .padding(.horizontal, SettingsLayout.rowPaddingH)
    .padding(.vertical, SettingsLayout.rowPaddingV)
  }

  private var countLabel: String {
    let shown = coordinator.filtered(by: query).count
    let total = coordinator.snippets.count
    if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "\(shown) of \(total)" }
    return total == 1 ? "1 snippet" : "\(total) snippets"
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.stTextTertiary)
        .accessibilityHidden(true)
      TextField("Search snippets", text: $query)
        .textFieldStyle(.plain)
    }
    .padding(.horizontal, SettingsLayout.rowPaddingH)
    .padding(.bottom, 10)
  }

  @ViewBuilder
  private var rows: some View {
    let shown = coordinator.filtered(by: query)
    if shown.isEmpty {
      VStack(spacing: 8) {
        Text("No snippets match \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}")
          .settingsRowLabel()
        SettingsActionButton(title: "Clear search", isEnabled: true, emphasis: .outlined) {
          query = ""
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 32)
    } else {
      ForEach(Array(shown.enumerated()), id: \.element.id) { index, snippet in
        if index > 0 { Divider().overlay(Color.stDivider) }
        row(snippet)
      }
    }
  }

  private func row(_ snippet: Snippet) -> some View {
    Button {
      sheetRoute = .edit(SnippetDraft(snippet: snippet))
    } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 7) {
            Text(snippet.trigger).settingsRowLabel()
            // Shown only while a starter is still exactly as it shipped. It is the one thing
            // standing between "John Doe" and a real message, and it disappears the moment the
            // user makes the snippet theirs, because the answer is recomputed from the text on
            // screen rather than stored.
            if SnippetStarters.isUneditedExample(snippet) { exampleTag }
          }
          // One line, ellipsised: an expansion can be a whole signature, and a list that grows
          // a row to fit one of them stops being scannable.
          Text(oneLine(snippet.expansion))
            .settingsHelperCopy()
            .lineLimit(1)
            .truncationMode(.tail)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.stTextTertiary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, SettingsLayout.rowPaddingH)
      .padding(.vertical, SettingsLayout.rowPaddingV)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      SnippetStarters.isUneditedExample(snippet)
        ? "\(snippet.trigger), example, pastes \(oneLine(snippet.expansion))"
        : "\(snippet.trigger), pastes \(oneLine(snippet.expansion))")
  }

  /// The quiet tag on an untouched starter. Outlined rather than filled: it labels the row, and
  /// a filled accent pill would read as a recommendation to keep the example rather than a note
  /// that it is one.
  private var exampleTag: some View {
    Text("Example")
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(Color.stTextTertiary)
      .padding(.horizontal, 7)
      .padding(.vertical, 1)
      .background(Capsule().strokeBorder(Color.stDivider, lineWidth: 1))
      .accessibilityHidden(true)
  }

  /// Line breaks flattened for the row preview only. The stored expansion keeps them — they are
  /// the point of the sign-off case.
  private func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).joined(separator: " ")
  }

  private var unreadableState: some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(.stWarning)
        .accessibilityHidden(true)
      Text("Your snippets could not be read").settingsRowTitle()
      Text(
        "They are still saved on your Mac. Nothing has been changed or deleted, and EnviousWispr will not write over them. Restart the app, and tell us if this keeps happening."
      )
      .settingsHelperCopy()
      .multilineTextAlignment(.center)
      .frame(maxWidth: 380)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
  }

  // MARK: - Empty state

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "curlybraces")
        .font(.system(size: 40, weight: .light))
        .foregroundStyle(Color.stAccent.opacity(0.25))
        .accessibilityHidden(true)
      Text("No snippets yet").settingsRowTitle()
      Text(
        "Save the text you type over and over. An email address, a signature, a link you always paste."
      )
      .settingsHelperCopy()
      .multilineTextAlignment(.center)
      .frame(maxWidth: 340)
      SettingsActionButton(title: "Add your first snippet", isEnabled: true, emphasis: .filled) {
        sheetRoute = .edit(SnippetDraft(snippet: nil))
      }
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 36)
  }
}

/// A sheet's subject, keyed by request rather than by a bare boolean, so `.sheet(item:)` gets a
/// fresh presentation per row — the pattern `YourWordsView` already uses for the same reason.
struct SnippetDraft: Identifiable {
  let id = UUID()
  let snippet: Snippet?
}

/// The one sheet the Snippets page can show at a time (#2997).
enum SnippetsSheetRoute: Identifiable {
  case edit(SnippetDraft)
  case importSnippets

  var id: String {
    switch self {
    case .edit(let draft): return "edit-\(draft.id.uuidString)"
    case .importSnippets: return "import"
    }
  }
}
