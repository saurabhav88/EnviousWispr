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

/// Scrolls the Dictionary page's content pane back to its first row.
///
/// Set by `YourWordsView`, which owns the scroll view; read by every paged
/// list inside it. The default is a no-op, so a list rendered outside that
/// pane — a preview, a test — simply does nothing rather than needing a
/// different code path. Mirrors `settingsNavigate`, the settings window's
/// other environment-carried action.
private struct DictionaryScrollToTopKey: EnvironmentKey {
  static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
  var dictionaryScrollToTop: @MainActor () -> Void {
    get { self[DictionaryScrollToTopKey.self] }
    set { self[DictionaryScrollToTopKey.self] = newValue }
  }
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

  /// One line under the tab name, the way every AI Polish rail row carries a
  /// tagline under its engine name (`PolishRailProvider.tagline`). A rail row
  /// that is a bare word makes the reader open each tab to learn what is in
  /// it; a tagline answers that from the rail.
  ///
  /// **Kept to about sixteen characters, and that is a measurement rather than
  /// a style preference.** The rail is 216pt; after the card's padding, the
  /// row's padding, the 32pt tile and the gap, a tagline gets roughly 132pt,
  /// which is about eighteen characters at this size. Longer copy truncates —
  /// measured 2026-08-29, when "Ready-made word lists" rendered as "Ready-made
  /// word l...". `ProviderRailRow` has the same constraint and lives with a
  /// truncated Ollama line; there is no reason to inherit that here when the
  /// shorter phrasing is just as true.
  var tagline: String {
    switch self {
    case .yourWords: return "Words you added"
    case .vocabularyPacks: return "Ready-made lists"
    case .learnFrom: return "Learn as you go"
    case .quickAdd: return "Add from any app"
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
  /// Identity of the zero-height anchor at the top of the scrolling pane.
  fileprivate static let topAnchor = "dictionaryPaneTop"

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

      HStack(alignment: .top, spacing: PolishRailMetrics.columnGap) {
        DictionaryTabRail(selection: $selectedTab)
          // `PolishRailMetrics.railWidth`, the SAME 216pt the AI Polish rail
          // uses, because these rows now carry the same content it does — a
          // 32pt tile, a name, and a tagline. The previous 168pt was chosen
          // for a row that was an icon and one word, and it truncated the
          // longest tab to "Vocabulary P..." at the window size the founder
          // actually runs (measured 2026-08-29 at 1115pt wide, nowhere near
          // the 750pt minimum the narrower value was defending).
          .frame(width: PolishRailMetrics.railWidth, alignment: .leading)

        // `ScrollViewReader` so a paged list can return to its first row.
        //
        // The scroll offset belongs to THIS view — there is one scroll view
        // for every tab — while the page buttons live two levels down, in
        // `CustomTermsSection` and `VocabularyPackDetailSection`. Without a way
        // to reach back up, pressing Next at the bottom of a 50-row page swaps
        // the rows underneath an unchanged offset, so the next page opens
        // somewhere in its middle and the reader has to scroll up to find its
        // start (cloud review, PR #2504).
        //
        // Handed down through the environment as ONE action rather than
        // solved twice: both paged lists are inside this scroll view and the
        // Your Words list has had the same defect since it shipped.
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
              selectedTabContent
            }
            .padding(.bottom, SettingsLayout.contentBottom)
            // The anchor the action scrolls to. Zero-height and behind
            // everything, so it changes nothing about the layout.
            .overlay(alignment: .top) {
              Color.clear.frame(height: 0).id(Self.topAnchor)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .environment(\.dictionaryScrollToTop) {
            withAnimation(.easeOut(duration: 0.18)) {
              proxy.scrollTo(Self.topAnchor, anchor: .top)
            }
          }
        }
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

      // The three page actions are handed to the list card rather than drawn
      // above it. They used to be their own right-aligned row, with the word
      // count on a third row below that, so the pane opened as three stacked
      // bands and the buttons belonged to nothing (founder, 2026-08-29: they
      // "push the whole UI down, making it look disjointed and not unified").
      // Count and actions are one bar now: what you have, and what you can do
      // to it.
      CustomTermsSection { actionButtons }
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

/// #2492: the Dictionary page's fixed left sub-menu, drawn as a CARD.
///
/// **The card is the whole point, and shipping without it is what made this
/// rail read as unfinished beside AI Polish's** (founder, 2026-08-29: "the sub
/// menu for dictionary looks janky compared to the ai polish sub menue"). Four
/// pills floating directly on the page background have no container, so the
/// empty space beneath the last tab belongs to nothing and the rail stops
/// looking like an object. `ProviderRail` solves the identical problem with a
/// `stSectionBg` fill, a `stDivider` border, radius 14 and 10pt of padding, and
/// the approved mockup (`.subnav-card`, `height:fit-content`) draws exactly
/// that. These are the same four values, read off `ProviderRail.body`.
///
/// Still its own type rather than a reuse of `ProviderRail`: that rail is
/// hard-wired to `PolishRailCatalog` and `LLMProvider`, and its rows draw a
/// `ProviderLogoTile` carrying six brand marks. What is shared is the visual
/// vocabulary, not the data model.
private struct DictionaryTabRail: View {
  @Binding var selection: DictionaryTab
  /// One highlight that GLIDES between rows rather than four that blink,
  /// matching `ProviderRail`'s `selectionNS`.
  @Namespace private var selectionNS
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(DictionaryTab.allCases) { tab in
        DictionaryTabRow(tab: tab, isSelected: selection == tab, namespace: selectionNS) {
          withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82)) {
            selection = tab
          }
        }
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius, style: .continuous)
        .fill(Color.stSectionBg)
    )
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius, style: .continuous)
        .strokeBorder(Color.stDivider, lineWidth: 1)
        // A decoration is never in the hit path. `strokeBorder` covers only
        // the 1pt ring, not the interior, so the tab buttons underneath stay
        // reachable either way — this is the house rule applied rather than a
        // defect repaired.
        .allowsHitTesting(false)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Dictionary section")
  }
}

private struct DictionaryTabRow: View {
  let tab: DictionaryTab
  let isSelected: Bool
  let namespace: Namespace.ID
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 12) {
        // A 32pt rounded tile, the same object `ProviderLogoTile` draws at the
        // same size in the AI Polish rail. A bare 15pt glyph beside 14pt text
        // has no weight of its own, which is the other half of why these rows
        // read as a list of links rather than a list of destinations.
        Image(systemName: tab.icon)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(isSelected ? Color.white : Color.stAccent)
          .frame(width: 32, height: 32)
          .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .fill(isSelected ? Color.stAccentSolid : Color.stAccentLight)
          )
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text(tab.label)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isSelected ? Color.stAccent : Color.stTextPrimary)
            .lineLimit(1)
            // The rail is sized for the longest label, but a user can shrink
            // the window; shrink the text a little before truncating it, the
            // way `ProviderRailRow` does for "Apple Intelligence".
            .minimumScaleFactor(0.85)
          Text(tab.tagline)
            .font(.stHelper)
            .foregroundStyle(Color.stTextSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 9)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.stAccentLight)
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.stAccent, lineWidth: 1.5)
            )
            .matchedGeometryEffect(id: "dictionaryTabSelection", in: namespace)
        }
      }
      // The shared hover treatment rather than a fifth hand-rolled one. It
      // paints the button's own rectangle, reads the environment's `isEnabled`,
      // and is not disabled by Reduce Motion — see `SettingsHover`.
      .settingsHoverRow(cornerRadius: 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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
