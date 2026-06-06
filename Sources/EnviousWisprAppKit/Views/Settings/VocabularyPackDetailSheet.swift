import EnviousWisprCore
import EnviousWisprPostProcessing
import SwiftUI

/// Read-only browser for a vocabulary pack's full term list (#992). Opens from a
/// pack row's "See all" button. A pinned search box filters an alphabetical list
/// of every word the pack fixes; each row shows the correct word plus the spoken
/// variants (aliases) it catches, as pills (mirroring the Custom Word edit sheet).
/// No editing — bundled packs are read-only.
struct VocabularyPackDetailSheet: View {
  let id: VocabularyPackID
  /// Pack terms (word + aliases), alphabetical by word, supplied by the section.
  let terms: [CustomWord]
  @State private var searchQuery: String = ""
  @Environment(\.dismiss) private var dismiss

  /// Rows whose word OR any alias contains the query (case-insensitive).
  private var filteredTerms: [CustomWord] {
    let query = searchQuery.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return terms }
    return terms.filter { term in
      term.canonical.localizedCaseInsensitiveContains(query)
        || term.aliases.contains { $0.localizedCaseInsensitiveContains(query) }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      // Title + count
      VStack(alignment: .leading, spacing: 2) {
        Text(id.displayName)
          .font(.headline)
        Text(
          "\(terms.count) \(terms.count == 1 ? "word" : "words") · the variants under each are examples of the mistakes it catches, not the full set"
        )
        .font(.stHelper)
        .foregroundStyle(.stTextTertiary)
        .fixedSize(horizontal: false, vertical: true)
      }

      // Search
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.stTextTertiary)
          .font(.system(size: 12))
        TextField("Search words or variants", text: $searchQuery)
          .textFieldStyle(.plain)
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
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(Color.stPageBg)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.stDivider, lineWidth: 1)
      )

      // Term list (or empty state)
      if filteredTerms.isEmpty {
        Spacer()
        Text(
          searchQuery.isEmpty
            ? "This pack has no words."
            : "No matches for \"\(searchQuery)\"."
        )
        .font(.stHelper)
        .foregroundStyle(.stTextTertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        Spacer()
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(filteredTerms.enumerated()), id: \.element.id) { index, term in
              termRow(term)
              if index < filteredTerms.count - 1 {
                Divider().overlay(Color.stDivider)
              }
            }
          }
        }
        .frame(maxWidth: .infinity)
      }

      // Done
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 420, height: 520)
  }

  /// One word + its alias pills.
  @ViewBuilder
  private func termRow(_ term: CustomWord) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(term.canonical)
        .font(.body)
      if term.aliases.isEmpty {
        Text("No spoken variants")
          .font(.system(size: 11))
          .foregroundStyle(.stTextTertiary)
      } else {
        WrappingHStack(spacing: 6) {
          ForEach(sortedAliases(term), id: \.self) { alias in
            Text(alias)
              .font(.system(size: 11))
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(Color.stAccentLight)
              .clipShape(RoundedRectangle(cornerRadius: 4))
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }

  private func sortedAliases(_ term: CustomWord) -> [String] {
    term.aliases.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }
}
