import EnviousWisprCore
import EnviousWisprServices
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
  @Environment(SettingsManager.self) private var settings
  @Environment(CustomWordsCoordinator.self) private var customWordsCoordinator
  @State private var addingNewTerm = false

  var body: some View {
    @Bindable var settings = settings

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
              .settingsReadingCopy()
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
            Toggle("Enable custom words", isOn: $settings.wordCorrectionEnabled)
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
        wordSuggestionService: customWordsCoordinator.suggestionService
      ) { newWord in
        let trimmedCanonical = newWord.canonical.trimmingCharacters(in: .whitespaces)
        guard !trimmedCanonical.isEmpty else { return nil }
        var wordToSave = newWord
        wordToSave.canonical = trimmedCanonical
        if let error = customWordsCoordinator.add(wordToSave) {
          return error
        }
        return nil
      }
    }
  }
}
