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

/// #2492: the Dictionary page's fixed left sub-menu, one case per tab. Owned
/// here (not a nested type) so a later phase (#2497, the Quick Add tab) adds
/// exactly one case rather than inventing a second tab mechanism — the
/// shared-plumbing seam the Gate 2 plan on #2491 calls out explicitly.
enum DictionaryTab: String, CaseIterable, Identifiable {
  case yourWords
  case vocabularyPacks
  case learnFrom
  // #2497: the fourth catalog entry the Phase 1 plan called for — no second
  // tab mechanism, no change to `DictionaryTabRail`/`DictionaryTabRow`.
  case quickAdd

  var id: Self { self }

  var label: String {
    switch self {
    case .yourWords: return "Your Words"
    case .vocabularyPacks: return "Vocabulary Packs"
    case .learnFrom: return "Learn from..."
    case .quickAdd: return "Quick Add"
    }
  }

  var icon: String {
    switch self {
    case .yourWords: return "textformat.abc"
    case .vocabularyPacks: return "shippingbox"
    case .learnFrom: return "sparkle.magnifyingglass"
    case .quickAdd: return "bolt"
    }
  }
}

/// #2492 — the Dictionary page (was "Your Words"). Rebuilt onto a fixed
/// banner + fixed left sub-menu + independently-scrolling right pane,
/// mirroring AI Polish's rail/detail visual language without reusing its
/// container: `SettingsContentView` puts its whole page (header included)
/// inside ONE `ScrollView`, and the founder's ask here is the opposite — the
/// banner and the tab list never move, only the selected tab's content does.
/// Internal type name is unchanged from the pre-redesign `YourWordsView`
/// (#2493 explicitly scopes the terminology pass to user-facing copy, not
/// Swift symbols).
struct YourWordsView: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(CustomWordsCoordinator.self) private var customWordsCoordinator
  @State private var selectedTab: DictionaryTab = .yourWords
  @State private var sheetRoute: YourWordsSheetRoute?
  // Outcome-to-message mapping is shared with `BulkDeleteConfirmSheet` so both
  // export entry points present the identical copy (#1703).
  @State private var exportNotice: CustomWordsExportNotice?

  var body: some View {
    @Bindable var settings = settings

    VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
      dictionaryBanner(settings: $settings)

      HStack(alignment: .top, spacing: 12) {
        DictionaryTabRail(selection: $selectedTab)
          // A dedicated width, not `PolishRailMetrics.railWidth` (216pt) —
          // that rail's rows carry a provider logo tile and a tagline; a
          // Dictionary tab is only an icon and one line of text, so it never
          // needed that width, and every point reclaimed here matters at the
          // app's 750pt minimum window (cloud review, PR #2499).
          .frame(width: 168, alignment: .leading)

        ScrollView {
          VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
            selectedTabContent
          }
          .padding(.bottom, SettingsLayout.contentBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .padding(.top, SettingsLayout.contentTop)
    .padding(.horizontal, SettingsLayout.contentH)
    .padding(.bottom, SettingsLayout.contentBottom)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.stPageBg)
    .tint(.stAccent)
    // 14pt floor for the whole page, matching `SettingsContentView` (founder
    // directive 2026-07-03) — this page opts out of that container's ONE
    // shared ScrollView, not out of its type scale.
    .font(.stBody)
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

  /// The fixed top banner: icon tile + title + description + the master
  /// on/off switch, merged into one bar per the founder's mockup feedback on
  /// #2491/#2492 (was a separate title card, a button row, and a toggle card
  /// stacked as three pieces).
  @ViewBuilder
  private func dictionaryBanner(settings: Bindable<SettingsManager>) -> some View {
    HStack(spacing: 14) {
      Image(systemName: "textformat.abc")
        .font(.system(size: 21, weight: .medium))
        .foregroundStyle(.stAccent)
        .frame(width: 46, height: 46)
        .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.stAccent.opacity(0.28), lineWidth: 1)
        )
        .accessibilityHidden(true)

      // .frame(maxWidth: .infinity): claims the HStack's remaining width so
      // the title row's Spacer below has room to push the toggle to the
      // banner's trailing edge, rather than the two hugging each other.
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 12) {
          Text("Dictionary")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.stTextPrimary)

          Spacer(minLength: 8)

          // .fixedSize(): BrandedToggleStyle's internal Spacer otherwise
          // claims whatever width this HStack hands it, which here would be
          // the banner's entire remaining row rather than the toggle's own
          // label-gap-track shape (#2492 review r1).
          Toggle(isOn: settings.wordCorrectionEnabled) {
            Text("Enable Dictionary").settingsRowLabel()
          }
          .toggleStyle(BrandedToggleStyle())
          .fixedSize()
        }

        // One line, guaranteed: at the app's 750pt minimum window this row
        // has ~460pt after the sidebar and the icon tile, which the fuller
        // sentence used to overflow. Reads `SettingsSection.wordCorrection`'s
        // subtitle rather than a second literal — every other settings page's
        // description lives there (rendered by `SettingsPageHeader`); this
        // banner is Dictionary's own header, so it reads the same source
        // instead of forking a duplicate string.
        Text(SettingsSection.wordCorrection.subtitle)
          .settingsReadingCopy()
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.stSectionBg)
    .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
        .strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }

  @ViewBuilder
  private var selectedTabContent: some View {
    switch selectedTab {
    case .yourWords:
      // Launch-time load failure (#1646): honest banner instead of a silent
      // empty list. Two distinct situations, two distinct messages.
      if let failure = customWordsCoordinator.wordsLoadFailureAtLaunch {
        WordsLoadFailureBanner(failure: failure)
      }

      // ViewThatFits: at the app's 750pt minimum window, the right pane is
      // roughly 228pt wide after the global sidebar, page padding, the
      // Dictionary rail, and its gap — one row of three labeled buttons
      // cannot stay readable there (#2492 review r1). The horizontal row is
      // tried first and used whenever the width allows it.
      ViewThatFits(in: .horizontal) {
        HStack {
          Spacer()
          actionButtons
        }
        VStack(alignment: .trailing, spacing: 8) {
          actionButtons
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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

      CustomTermsSection()
    case .vocabularyPacks:
      VocabPacksSection()
    case .learnFrom:
      LearningSection()
    case .quickAdd:
      QuickAddTeachingSection()
    }
  }

  /// The Your Words tab's three page-level actions, factored out so
  /// `ViewThatFits` can try them in a row and fall back to a column without
  /// duplicating each button's title, icon, and action closure.
  @ViewBuilder
  private var actionButtons: some View {
    // Three page-level actions that were on the system default style, which
    // on this dark surface renders as the same grey as a disabled control
    // and gives no hover of its own. Add word is the primary, so it is the
    // one that fills.
    SettingsActionButton(
      title: "Add word", isEnabled: true, emphasis: .filled, systemImage: "plus"
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

/// #2492: the Dictionary page's fixed left sub-menu. Deliberately its own
/// small view rather than a reuse of `ProviderRail` — that rail's row draws a
/// provider logo tile and a tagline (`ProviderLogoTile`, `entry.tagline`),
/// neither of which a Dictionary tab has; forcing this onto that type would
/// mean widening it with fields only this caller sends.
private struct DictionaryTabRail: View {
  @Binding var selection: DictionaryTab

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(DictionaryTab.allCases) { tab in
        DictionaryTabRow(tab: tab, isSelected: selection == tab) {
          selection = tab
        }
      }
    }
  }
}

private struct DictionaryTabRow: View {
  let tab: DictionaryTab
  let isSelected: Bool
  let onSelect: () -> Void
  /// See `SettingsHover.respondsToPointer`.
  @Environment(\.isEnabled) private var environmentEnabled
  @State private var pointerInside = false

  private var hovering: Bool {
    SettingsHover.respondsToPointer(pointerInside, true, environmentEnabled)
  }

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 10) {
        Image(systemName: tab.icon)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(isSelected ? Color.stAccent : Color.stTextSecondary)
          .frame(width: 20)
          .accessibilityHidden(true)
        Text(tab.label)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(isSelected ? Color.stAccent : Color.stTextPrimary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.stAccentLight)
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.stAccent, lineWidth: 1.5)
            )
        } else if hovering {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.stTextPrimary.opacity(0.05))
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { pointerInside = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(tab.label)
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
    .accessibilityHint("Shows the \(tab.label) Dictionary tab")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
