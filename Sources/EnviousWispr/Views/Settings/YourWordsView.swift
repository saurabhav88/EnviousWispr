import EnviousWisprCore
import SwiftUI

/// Phase 4 (#634) — Your Words settings tab. Replaces the monolithic
/// `WordFixSettingsView` with a 3-section hub matching the founder-approved
/// 2026-05-04 mockup. Bible §10.
///
/// - Header: title + description + "+ Add term" CTA top-right.
/// - LearningSection: rows for Phase 6 + Phase 7 (disabled until those land).
/// - VocabPacksSection: empty state until Phase 5.
/// - CustomTermsSection: search + pagination + Edit per term.
struct YourWordsView: View {
  @Environment(AppState.self) private var appState
  @State private var addingNewTerm = false

  var body: some View {
    @Bindable var state = appState

    SettingsContentView {
      // Header
      BrandedSection {
        BrandedRow(showDivider: false) {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Your Words")
                .font(.title3)
                .bold()
              Text(
                "Custom terms, vocabulary packs, and learning sources EnviousWispr uses to recognize what you say."
              )
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
            }
            Spacer()
            Button {
              addingNewTerm = true
            } label: {
              Label("Add term", systemImage: "plus")
            }
          }
        }
      }

      // Master toggle (preserves the Enable custom words switch from the old view)
      BrandedSection {
        BrandedRow(showDivider: false) {
          VStack(alignment: .leading, spacing: 4) {
            Toggle("Enable custom words", isOn: $state.settings.wordCorrectionEnabled)
              .toggleStyle(BrandedToggleStyle())
            Text(
              "Automatically fix words the speech engine gets wrong using your custom list below."
            )
            .font(.stHelper)
            .foregroundStyle(.stTextTertiary)
          }
        }
      }

      LearningSection()
      VocabPacksSection()
      CustomTermsSection()
    }
    .sheet(isPresented: $addingNewTerm) {
      CustomWordEditSheet(
        word: CustomWord(canonical: ""),
        wordSuggestionService: appState.customWordsCoordinator.suggestionService
      ) { newWord in
        let trimmedCanonical = newWord.canonical.trimmingCharacters(in: .whitespaces)
        guard !trimmedCanonical.isEmpty else { return }
        // Skip enrichment in two cases:
        //  1. `add()` was a no-op because the canonical already exists as a user
        //     word — `existingIDs` catches that.
        //  2. `add()` restored a previously-deleted built-in (e.g. "GitHub")
        //     whose curated aliases must not be overwritten by sheet defaults.
        //     Detected by the restored entry already carrying aliases.
        let existingIDs = Set(appState.customWordsCoordinator.customWords.map(\.id))
        appState.customWordsCoordinator.add(trimmedCanonical)
        if let added = appState.customWordsCoordinator.customWords.first(where: {
          $0.canonical.caseInsensitiveCompare(trimmedCanonical) == .orderedSame
            && !existingIDs.contains($0.id)
            && $0.aliases.isEmpty
        }) {
          var enriched = added
          enriched.aliases = newWord.aliases
          enriched.category = newWord.category
          enriched.forceReplace = newWord.forceReplace
          enriched.minSimilarityOverride = newWord.minSimilarityOverride
          appState.customWordsCoordinator.update(enriched)
        }
      }
    }
  }
}
