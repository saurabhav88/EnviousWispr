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
  // Outcome-to-message mapping is shared with `BulkDeleteConfirmSheet` so both
  // export entry points present the identical copy (#1703).
  @State private var exportNotice: CustomWordsExportNotice?

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
        // Three page-level actions that were on the system default style, which
        // on this dark surface renders as the same grey as a disabled control
        // and gives no hover of its own. Add term is the primary, so it is the
        // one that fills.
        SettingsActionButton(
          title: "Add term", isEnabled: true, emphasis: .filled, systemImage: "plus"
        ) {
          sheetRoute = .addTerm
        }
        // The ONLY doorway into Custom Words import (epic #1619). Shipped to
        // release users from v2.4.1 by founder decision, 2026-07-24; every
        // import PR still carries "adds no second entry point" in its
        // definition of done, so this stays the single doorway.
        SettingsActionButton(
          title: "Import", isEnabled: true, systemImage: "square.and.arrow.down"
        ) {
          sheetRoute = .importWords
        }
        // Export (#1680). ONE body-render snapshot drives both the count shown
        // in the save dialog and the array handed to the action, so the number
        // the user reads and the bytes written cannot come from different
        // moments (#1697). The sentence itself lives in the dialog, not on this
        // screen: a paragraph wedged between two buttons competes with them
        // (#1715).
        let proposed = CustomWordsExportAction.exportableWords(
          from: customWordsCoordinator.customWords)
        SettingsActionButton(
          title: "Export your words", isEnabled: true,
          systemImage: "square.and.arrow.up"
        ) {
          exportWords(proposed: proposed)
        }
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

      // Visibility and the progress numerator both read `pendingEnrichmentCount`
      // — the observable in-memory count, never `pendingEnrichmentWords()`
      // (a real locked file read) and never the total's mere presence
      // (Codex Chunk 2 review finding 5: neither belongs in a SwiftUI
      // `body`, and the durable total can theoretically lag live state
      // during the brief self-heal window). The durable total remains the
      // denominator when available, falling back to the live count itself
      // as an honest floor if the total is momentarily nil.
      let pendingCount = customWordsCoordinator.pendingEnrichmentCount
      if pendingCount > 0 {
        BulkImportEnrichmentProgressCard(
          total: customWordsCoordinator.pendingEnrichmentBatchTotal ?? pendingCount,
          pendingCount: pendingCount,
          recent: customWordsCoordinator.mostRecentEnrichment,
          onCancel: { customWordsCoordinator.cancelBulkImportEnrichment?() }
        )
      }

      LearningSection()
      VocabPacksSection()
      CustomTermsSection()
    }
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
        chooseDestination: {
          CustomWordsExportPanel.chooseDestination(exportableCount: proposed.count)
        },
        write: { document, destination in
          try await CustomWordsExportWriter.write(document, to: destination)
        }
      )
      exportNotice = CustomWordsExportNotice.forOutcome(outcome)
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

/// Bulk-import-enrichment progress card (#1701 Chunk 2). Visible whenever a
/// background enrichment run is in progress. Real progress against the
/// durable total (never a timed animation standing in for it); once at least
/// one word has actually completed, the word-transform display shows the
/// actual word and its actual freshly generated aliases (mockup:
/// docs/feature-requests/issue-1701-mockup-flow.html). A word that completed
/// with no useful aliases shows no transform row for that moment — nothing
/// honest to display.
private struct BulkImportEnrichmentProgressCard: View {
  let total: Int
  let pendingCount: Int
  let recent: CustomWordEnrichmentDisplay?
  let onCancel: () -> Void

  private var processedCount: Int { max(0, total - pendingCount) }
  private var fraction: Double {
    guard total > 0 else { return 0 }
    return Double(processedCount) / Double(total)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Importing your words").settingsRowLabel()
        Spacer()
        Button(action: onCancel) {
          // The only way out of a running import, drawn as accent-coloured
          // helper text -- which on this page is also how non-interactive
          // labels are drawn.
          Text("Cancel").settingsHoverQuiet()
        }
        .buttonStyle(.plain)
        .font(.stHelper)
        .foregroundStyle(.stAccent)
      }

      ProgressView(value: fraction)
        .tint(.stAccentSolid)

      HStack(alignment: .firstTextBaseline) {
        Text("\(processedCount) of \(total) processed")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        Spacer(minLength: 8)
        if let recent, !recent.generatedAliases.isEmpty {
          HStack(spacing: 4) {
            Text(recent.canonical)
              .foregroundStyle(.stTextBody)
            Image(systemName: "arrow.right")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.stTextTertiary)
              .accessibilityHidden(true)
            Text(recent.generatedAliases.joined(separator: ", "))
              .foregroundStyle(.stAccent)
          }
          .font(.stHelper)
          .lineLimit(1)
          .truncationMode(.tail)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(
            "\(recent.canonical) now recognizes \(recent.generatedAliases.joined(separator: ", "))"
          )
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
        .strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }
}
