import EnviousWisprCore
import SwiftUI

/// A pending bulk-delete confirmation, keyed by request rather than a bare
/// boolean (#1703) — the confirmation's content depends on which IDs were
/// selected, so `.sheet(item:)` is the correct presentation, matching the
/// data-dependent sheet pattern this repo already uses (`YourWordsView`).
private struct BulkDeleteRequest: Identifiable {
  let id = UUID()
  let ids: Set<UUID>
}

/// Phase 4 (#634) — Custom Terms section. Search + pagination + per-term Edit.
/// Reads `frequencyUsed` from Phase 3a/b for "used N times" subtitle (omitted
/// when frequency is 0 to avoid the "0 times" looks-like-a-bug case). Bible §10.2.
/// Bulk select/delete (#1703): a "Select" mode lets several of the user's own
/// words be checked off and removed in one action.
struct CustomTermsSection: View {
  @Environment(CustomWordsCoordinator.self) private var customWordsCoordinator
  @State private var searchQuery: String = ""
  @State private var currentPage: Int = 0
  @State private var editingWord: CustomWord?
  @State private var isSelecting = false
  @State private var selectedIDs: Set<UUID> = []
  @State private var pendingBulkDelete: BulkDeleteRequest?

  private var allWords: [CustomWord] {
    customWordsCoordinator.customWords
  }

  private var filteredWords: [CustomWord] {
    CustomTermListPolicy.filtered(allWords, query: searchQuery)
  }

  /// IDs eligible for bulk selection within the current search/filter — never
  /// the whole library, and never a built-in or vocabulary-pack term. One
  /// projection reused by both the Select-All control and row rendering.
  private var filteredSelectableIDs: Set<UUID> {
    CustomTermListPolicy.selectableIDs(in: filteredWords)
  }

  private var pageCount: Int {
    CustomTermListPolicy.pageCount(of: filteredWords.count)
  }

  private var pagedWords: [CustomWord] {
    let safePage = max(0, min(currentPage, pageCount - 1))
    return CustomTermListPolicy.paged(filteredWords, page: safePage)
  }

  var body: some View {
    BrandedSection(header: "Custom terms · \(filteredWords.count)") {
      // Search + selection controls
      BrandedRow(showDivider: true) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.stTextSecondary)
            .font(.system(size: 12))
          TextField("Search by name, alias, or category", text: $searchQuery)
            .textFieldStyle(.plain)
            .onChange(of: searchQuery) { _, _ in currentPage = 0 }
            .onChange(of: pageCount) { _, newCount in
              if currentPage >= newCount { currentPage = max(0, newCount - 1) }
            }
          if !searchQuery.isEmpty {
            Button {
              searchQuery = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.stTextSecondary)
                .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear search")
          }
          Spacer()
          selectionControls
        }
      }

      // List or empty state
      if pagedWords.isEmpty {
        BrandedRow(showDivider: false) {
          Text(
            searchQuery.isEmpty
              ? "No custom terms yet. Add one with the button above."
              : "No matches for \"\(searchQuery)\"."
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        }
      } else {
        ForEach(Array(pagedWords.enumerated()), id: \.element.id) { idx, word in
          BrandedRow(showDivider: idx < pagedWords.count - 1 || pageCount > 1) {
            termRow(for: word)
          }
        }
      }

      // Bulk-delete action row, shown only once something is selected.
      if isSelecting, !selectedIDs.isEmpty {
        BrandedRow(showDivider: false) {
          HStack {
            Text("\(selectedIDs.count) selected")
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
            Spacer()
            Button("Delete…", role: .destructive) {
              pendingBulkDelete = BulkDeleteRequest(ids: selectedIDs)
            }
            .controlSize(.small)
          }
        }
      }

      // Pagination (only shown when filtered count exceeds one page)
      if pageCount > 1 {
        BrandedRow(showDivider: false) {
          HStack {
            Button {
              if currentPage > 0 { currentPage -= 1 }
            } label: {
              Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(currentPage == 0)
            .accessibilityLabel("Previous page")
            Spacer()
            Text("Page \(currentPage + 1) of \(pageCount)")
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
            Spacer()
            Button {
              if currentPage < pageCount - 1 { currentPage += 1 }
            } label: {
              Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(currentPage >= pageCount - 1)
            .accessibilityLabel("Next page")
          }
        }
      }
    }
    .onChange(of: allWords) { _, newWords in
      // Prune against current ELIGIBILITY, not merely current ID existence:
      // if a live refresh replaces an already-selected ID with a word that
      // still exists but is no longer the user's own, drop it too (#1703).
      selectedIDs.formIntersection(CustomTermListPolicy.selectableIDs(in: newWords))
    }
    .sheet(item: $editingWord) { word in
      CustomWordEditSheet(
        word: word,
        wordSuggestionService: customWordsCoordinator.suggestionService,
        onSave: { updated in
          customWordsCoordinator.update(updated)
        },
        onDelete: {
          customWordsCoordinator.remove(id: word.id)
        }
      )
    }
    .sheet(item: $pendingBulkDelete) { request in
      BulkDeleteConfirmSheet(
        ids: request.ids,
        onDeleted: {
          selectedIDs.subtract(request.ids)
          isSelecting = false
          pendingBulkDelete = nil
        },
        onCancel: { pendingBulkDelete = nil }
      )
    }
  }

  @ViewBuilder
  private func termRow(for word: CustomWord) -> some View {
    if isSelecting, filteredSelectableIDs.contains(word.id) {
      Toggle(
        isOn: Binding(
          get: { selectedIDs.contains(word.id) },
          set: { selected in
            if selected {
              selectedIDs.insert(word.id)
            } else {
              selectedIDs.remove(word.id)
            }
          }
        )
      ) {
        termLabel(for: word)
      }
      .toggleStyle(.checkbox)
    } else {
      HStack {
        termLabel(for: word)
        Spacer()
        // Edit is unavailable while selecting — structurally, not merely by
        // convention, so the two sheets this section presents never both
        // apply to the same row at once.
        if !isSelecting {
          Button("Edit") {
            editingWord = word
          }
          .controlSize(.small)
        }
      }
    }
  }

  private func termLabel(for word: CustomWord) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(word.canonical)
        .font(.body)
      Text(usageSubtitle(for: word))
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
    }
  }

  /// Trailing controls in the search row: "Select" when idle (only offered
  /// if there is anything selectable in the current filtered set), or
  /// "Select All"/"Deselect All" + "Cancel" while selecting.
  @ViewBuilder
  private var selectionControls: some View {
    if isSelecting {
      let allSelected =
        !filteredSelectableIDs.isEmpty && filteredSelectableIDs.isSubset(of: selectedIDs)
      Button(allSelected ? "Deselect All" : "Select All") {
        selectedIDs = CustomTermListPolicy.toggledSelection(
          current: selectedIDs, target: filteredSelectableIDs)
      }
      .controlSize(.small)
      .disabled(filteredSelectableIDs.isEmpty)

      Button("Cancel") {
        selectedIDs = []
        isSelecting = false
      }
      .controlSize(.small)
    } else if !filteredSelectableIDs.isEmpty {
      Button("Select") {
        isSelecting = true
      }
      .controlSize(.small)
    }
  }

  /// "<Category> · used N times" when frequencyUsed > 0; just the category
  /// otherwise. Hides the "0 times" case to avoid looking like a bug.
  private func usageSubtitle(for word: CustomWord) -> String {
    let categoryLabel = word.category.rawValue.capitalized
    if word.frequencyUsed > 0 {
      return "\(categoryLabel) · used \(word.frequencyUsed) times"
    }
    return categoryLabel
  }
}
