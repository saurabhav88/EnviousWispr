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
    /// What to say after an export attempt. Two kinds, deliberately: a real
    /// failure, and an honest outcome that is not a failure. Sharing one
    /// "Export didn't finish" title for both would tell a pack-only user their
    /// export broke when it worked exactly as designed (#1697).
    enum ExportNotice: Equatable {
      case failure(String)
      case info(String)

      var title: String {
        switch self {
        case .failure: return "Export didn't finish"
        case .info: return "Nothing was exported"
        }
      }

      var message: String {
        switch self {
        case .failure(let text), .info(let text): return text
        }
      }
    }

    @State private var exportNotice: ExportNotice?
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
          // The ONLY doorway into Custom Words import, and deliberately
          // DEBUG-only.
          //
          // This is founder policy, not an oversight or an unfinished edge
          // (epic #1619, restated 2026-07-19): the whole import feature is
          // compiled out of release builds until the founder decides it ships,
          // and every import PR carries "adds no second entry point" in its
          // definition of done. The mechanism is compile-time exclusion rather
          // than a runtime toggle precisely because a runtime toggle ships in
          // release and is user-discoverable — the exact bleed being avoided.
          //
          // Reviewers reasonably read a real, working, unreachable feature as
          // a bug — it was raised as a P1 on #1681 — so the reason lives here,
          // next to the gate, rather than only in the issue tracker. Removing
          // this gate is a founder decision, not a code-review one.
          Button {
            sheetRoute = .importWords
          } label: {
            Label("Preview import", systemImage: "square.and.arrow.down")
          }
          // Export (#1680). Also DEBUG-only: the whole import/export feature is
          // compiled out of release builds until the founder ships it, and a
          // release-visible Export whose companion Import is invisible would be
          // half a promise.
          // ONE body-render snapshot drives both the visible count and the
          // array handed to the action, so the number the user reads and the
          // bytes written cannot come from different moments (#1697).
          let proposed = CustomWordsExportAction.exportableWords(
            from: customWordsCoordinator.customWords)
          Text(exportCountSummary(proposed.count))
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
          Button {
            exportWords(proposed: proposed)
          } label: {
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
        exportNotice?.title ?? "",
        isPresented: Binding(
          get: { exportNotice != nil },
          set: { if !$0 { exportNotice = nil } }
        )
      ) {
        Button("OK", role: .cancel) { exportNotice = nil }
      } message: {
        Text(exportNotice?.message ?? "")
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
    private func exportWords(proposed: [CustomWord]) {
      // The decision lives in CustomWordsExportAction so the ORDER of its
      // steps is testable; this is just the wiring (#1680).
      Task {
        let outcome = await CustomWordsExportAction.run(
          coordinator: customWordsCoordinator,
          proposedExportWords: proposed,
          chooseDestination: { CustomWordsExportPanel.chooseDestination() },
          write: { document, destination in
            try await CustomWordsExportWriter.write(document, to: destination)
          }
        )
        switch outcome {
        case .cancelled, .exported:
          exportNotice = nil
        case .refusedUnsafeLibrary:
          exportNotice = .failure(
            "Your saved words couldn't be read this time, so there's nothing safe to export. "
              + "Relaunch EnviousWispr and try again.")
        // Neither of the next two is a failure, so neither wears the failure
        // title. A pack-only user pressing Export has done nothing wrong; they
        // need the reason their long word list produced no file (#1697).
        case .nothingToExport:
          exportNotice = .info(
            "There are no words of your own to export yet. "
              + "Vocabulary packs are not included.")
        case .libraryChanged:
          exportNotice = .info(
            "Your word list changed. Nothing was exported. "
              + "Review the updated count and try Export again.")
        case .failed(let message):
          exportNotice = .failure(message)
        }
      }
    }

    /// Says what Export will actually produce, before it is pressed.
    private func exportCountSummary(_ count: Int) -> String {
      switch count {
      case 0: return "No words of your own yet. Packs aren't included."
      case 1: return "Exporting 1 word of your own. Packs aren't included."
      default: return "Exporting \(count) of your own words. Packs aren't included."
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
