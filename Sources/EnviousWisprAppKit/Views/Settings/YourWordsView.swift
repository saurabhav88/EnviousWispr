import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import SwiftUI

/// Which sheet Your Words is presenting (#1657): the Add-term editor or the
/// Custom Words import shell. One route + `.sheet(item:)` because the view
/// now presents two different sheets.
private enum YourWordsSheetRoute: String, Identifiable {
  case addTerm
  case importWords
  var id: Self { self }
}

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
  @State private var sheetRoute: YourWordsSheetRoute?

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      // Launch-time load failure (#1646): honest banner instead of a silent
      // empty list. Two distinct situations, two distinct messages.
      if let failure = customWordsCoordinator.wordsLoadFailureAtLaunch {
        WordsLoadFailureBanner(failure: failure)
      }

      // "Add term" action (the page title + description now live in the page header).
      HStack {
        Spacer()
        Button {
          sheetRoute = .addTerm
        } label: {
          Label("Add term", systemImage: "plus")
        }
        #if DEBUG
          // Import shell fixture walk (#1657). DEBUG-only until a real import
          // source ships — a release-visible entry whose screens only show
          // fixtures would ship a broken promise.
          Button {
            sheetRoute = .importWords
          } label: {
            Label("Preview import", systemImage: "square.and.arrow.down")
          }
        #endif
      }

      // Master toggle (preserves the Enable custom words switch from the old view)
      BrandedSection {
        BrandedRow(showDivider: false) {
          HStack(alignment: .top, spacing: 11) {
            SettingsRowIcon(systemName: "textformat.abc")
            VStack(alignment: .leading, spacing: 4) {
              Toggle(isOn: $settings.wordCorrectionEnabled) {
                Text("Enable custom words").settingsRowLabel()
              }
              .toggleStyle(BrandedToggleStyle())
              Text(
                "Automatically fix words the speech engine gets wrong using your custom list below."
              )
              .settingsReadingCopy()
            }
          }
        }
      }

      LearningSection()
      VocabPacksSection()
      CustomTermsSection()
    }
    .sheet(item: $sheetRoute) { route in
      switch route {
      case .addTerm:
        CustomWordEditSheet(
          word: CustomWord(canonical: ""),
          wordSuggestionService: customWordsCoordinator.suggestionService,
          onSave: saveNewWord
        )
      case .importWords:
        // The import flow reads the live list and commits through the same
        // coordinator every other Your Words mutation uses (#1669) — two
        // narrow closures rather than handing the sheet the coordinator.
        CustomWordsImportSheet(
          dependencies: .live(
            existingWords: { customWordsCoordinator.customWords },
            commit: { customWordsCoordinator.commitImport($0) }
          )
        )
      }
    }
  }

  private func saveNewWord(_ newWord: CustomWord) -> String? {
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

/// Warning-tinted page banner for a failed launch-time words load (#1646).
/// Mirrors `FrozenPerRecordingBanner`'s shape with the warning palette.
private struct WordsLoadFailureBanner: View {
  let failure: CustomWordsInitialLoadFailure

  private var message: String {
    switch failure {
    case .unreadable:
      return
        "Your saved words couldn't be read this time. Nothing was changed or deleted. Try relaunching."
    case .corrupted:
      return
        "Your saved words file was damaged and moved aside for recovery. EnviousWispr started with an empty saved list."
    }
  }

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.stWarning)
        .accessibilityHidden(true)
      Text(message)
        .font(.stHelper)
        .foregroundStyle(.stTextBody)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.stWarningSoft, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.stWarning.opacity(0.25), lineWidth: 1)
    )
  }
}
