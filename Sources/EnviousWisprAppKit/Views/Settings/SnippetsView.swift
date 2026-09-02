import EnviousWisprCore
import SwiftUI

/// The Snippets page (#628), built to the approved Claude Design prototype
/// (`docs/feature-requests/issue-628-design/EnviousWispr Snippets.dc.html`).
///
/// Three cards: the keyword, the list, and — when the list is empty — the state that explains
/// what a snippet is for. Import ships visible and DISABLED, marked "Coming soon" (founder,
/// 2026-09-01): the button occupies the place the design gives it so the shape of the screen
/// does not change when the flow lands.
struct SnippetsView: View {
  @Environment(SnippetsCoordinator.self) private var coordinator

  @State private var query = ""
  @State private var editing: SnippetDraft?
  @State private var keywordField = ""
  /// Held here rather than on the coordinator: an export never changes the store, so a failed
  /// one must not sit in the same slot as a failed save and read as though a snippet was lost.
  @State private var exportMessage: String?

  var body: some View {
    SettingsContentView {
      keywordCard
      listCard
    }
    .onAppear { keywordField = coordinator.keyword }
    .sheet(item: $editing) { draft in
      SnippetEditSheet(draft: draft, keyword: coordinator.keyword)
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
          .onSubmit { commitKeyword() }
        Text("then your snippet, and it expands.").settingsHelperCopy()
        Spacer(minLength: 0)
      }
    } footnote: {
      // The example is worth its line: the rule is easy to state and easy to misread, and one
      // concrete sentence answers "so what do I actually say" faster than the description.
      Text(
        "Example — say \u{201C}\(coordinator.keyword) my email address\u{201D} and your email is pasted."
      )
      .settingsHelperCopy()
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
        if coordinator.snippets.isEmpty {
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
      // Visible and inert, on purpose. A greyed control with an honest label tells the user the
      // path exists and is not ready; hiding it would make the feature look absent instead.
      SettingsActionButton(title: "Import", isEnabled: false, emphasis: .outlined) {}
        .help("Coming soon")
      SettingsActionButton(
        title: "Export", isEnabled: !coordinator.snippets.isEmpty, emphasis: .outlined
      ) {
        exportMessage = SnippetsExportAction.message(
          for: SnippetsExportAction.run(vocabulary: coordinator.vocabulary))
      }
      SettingsActionButton(title: "Add snippet", isEnabled: true, emphasis: .filled) {
        editing = SnippetDraft(snippet: nil)
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
      editing = SnippetDraft(snippet: snippet)
    } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(snippet.trigger).settingsRowLabel()
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
    .accessibilityLabel("\(snippet.trigger), pastes \(oneLine(snippet.expansion))")
  }

  /// Line breaks flattened for the row preview only. The stored expansion keeps them — they are
  /// the point of the sign-off case.
  private func oneLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).joined(separator: " ")
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
        editing = SnippetDraft(snippet: nil)
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
