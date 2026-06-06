import EnviousWisprPostProcessing
import SwiftUI

/// Read-only browser for a vocabulary pack's full word list (#992). Opens when a
/// pack row is tapped. A pinned search box filters an alphabetical list of every
/// correctable word in the pack. No editing — bundled packs are read-only.
struct VocabularyPackDetailSheet: View {
  let id: VocabularyPackID
  /// Alphabetical canonicals, supplied by the section so the sheet stays dumb.
  let words: [String]
  @State private var searchQuery: String = ""
  @Environment(\.dismiss) private var dismiss

  private var filteredWords: [String] {
    let query = searchQuery.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return words }
    return words.filter { $0.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      // Title + count
      VStack(alignment: .leading, spacing: 2) {
        Text(id.displayName)
          .font(.headline)
        Text("\(words.count) \(words.count == 1 ? "word" : "words") this pack can fix")
          .font(.stHelper)
          .foregroundStyle(.stTextTertiary)
      }

      // Search
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.stTextTertiary)
          .font(.system(size: 12))
        TextField("Search words", text: $searchQuery)
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

      // Word list (or empty state)
      if filteredWords.isEmpty {
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
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(filteredWords.enumerated()), id: \.element) { index, word in
              Text(word)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
              if index < filteredWords.count - 1 {
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
    .frame(width: 400, height: 480)
  }
}
