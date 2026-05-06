import EnviousWisprCore
import SwiftUI

/// Phase 4 (#634) — Custom Terms section. Search + pagination + per-term Edit.
/// Reads `frequencyUsed` from Phase 3a/b for "used N times" subtitle (omitted
/// when frequency is 0 to avoid the "0 times" looks-like-a-bug case). Bible §10.2.
struct CustomTermsSection: View {
  @Environment(AppState.self) private var appState
  @State private var searchQuery: String = ""
  @State private var currentPage: Int = 0
  @State private var editingWord: CustomWord?

  private var allWords: [CustomWord] {
    appState.customWordsCoordinator.customWords
  }

  private var filteredWords: [CustomWord] {
    CustomTermListPolicy.filtered(allWords, query: searchQuery)
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
      // Search
      BrandedRow(showDivider: true) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.stTextTertiary)
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
                .foregroundStyle(.stTextTertiary)
                .font(.system(size: 12))
            }
            .buttonStyle(.plain)
          }
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
          .foregroundStyle(.stTextTertiary)
        }
      } else {
        ForEach(Array(pagedWords.enumerated()), id: \.element.id) { idx, word in
          BrandedRow(showDivider: idx < pagedWords.count - 1 || pageCount > 1) {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(word.canonical)
                  .font(.body)
                Text(usageSubtitle(for: word))
                  .font(.stHelper)
                  .foregroundStyle(.stTextTertiary)
              }
              Spacer()
              Button("Edit") {
                editingWord = word
              }
              .controlSize(.small)
            }
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
          }
        }
      }
    }
    .sheet(item: $editingWord) { word in
      CustomWordEditSheet(
        word: word,
        wordSuggestionService: appState.customWordsCoordinator.suggestionService,
        onSave: { updated in
          appState.customWordsCoordinator.update(updated)
        },
        onDelete: {
          appState.customWordsCoordinator.remove(id: word.id)
        }
      )
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
