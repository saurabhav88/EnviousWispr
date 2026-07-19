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
  #if DEBUG
    /// Set when an export failed, so the failure is stated rather than silent.
    @State private var exportError: String?
  #endif

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
          // Export (#1680). Also DEBUG-only: the whole import/export feature is
          // compiled out of release builds until the founder ships it, and a
          // release-visible Export whose companion Import is invisible would be
          // half a promise.
          Button(action: exportWords) {
            Label("Export your words", systemImage: "square.and.arrow.up")
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
    #if DEBUG
      .alert(
        "Export didn't finish",
        isPresented: Binding(
          get: { exportError != nil },
          set: { if !$0 { exportError = nil } }
        )
      ) {
        Button("OK", role: .cancel) { exportError = nil }
      } message: {
        Text(exportError ?? "")
      }
    #endif
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

  #if DEBUG
    /// Export the user's own words (#1680).
    ///
    /// Order matters: the destination is chosen first, and only then is the
    /// word list snapshotted — so cancelling reads nothing and writes nothing.
    /// Built-ins are excluded; what ships is what the user authored or edited,
    /// which is the only scope whose restore path this app can actually honor.
    private func exportWords() {
      // Refuse to export what we could not read (code review r3). When the
      // launch-time load fails the coordinator holds an empty list while the
      // real file may still be on disk or archived for recovery. Exporting
      // then writes a VALID EMPTY backup — and can overwrite a good one — so
      // the failure would destroy the very thing the user came here to save.
      // The banner already explains the load failure; this says why the button
      // did nothing.
      if !customWordsCoordinator.savedWordsAreReadable {
        exportError =
          "Your saved words couldn't be read this time, so there's nothing safe to export. "
          + "Relaunch EnviousWispr and try again."
        return
      }
      guard let destination = CustomWordsExportPanel.chooseDestination() else { return }
      // Snapshot on the main actor, write off it (code review r5). The list is
      // read here, synchronously, so the file reflects the moment the user
      // confirmed rather than whenever the write happened to run; only the
      // filesystem work moves off, so a slow network or cloud destination
      // cannot freeze the settings window.
      let document = CustomWordsTransferDocument(
        words: customWordsCoordinator.customWords.filter { $0.source == .user })
      Task {
        do {
          try await CustomWordsExportWriter.write(document, to: destination)
          exportError = nil
        } catch {
          exportError = error.localizedDescription
        }
      }
    }
  #endif

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
