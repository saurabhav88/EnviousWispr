import EnviousWisprLivePreview
import SwiftUI

/// The Apple language catalogue, as a sheet rather than fifty-four rows on the page (#2436).
///
/// **Why it left the page.** Founder, 2026-08-25: the settings page had "a super long
/// never ending scrolling language selector". Measured on his Mac the day #2080 shipped:
/// one language installed, fifty-three downloadable, so the tallest thing on a page about
/// switching a feature on was fifty-three downloads nobody asked for.
///
/// **The split it preserves is the founder's, not a new one** (`live-preview.md`
/// RULE: the-picker-offers-what-works-now-the-table-is-the-catalogue): the picker answers
/// "what can I switch to right now" and lists installed languages only; THIS is the
/// catalogue, the only place a language is acquired. #2436 makes that split physical —
/// two sheets — instead of a sheet and an inline table.
///
/// Carried verbatim from `packsSection`, on why the Source column existed and why it does
/// not need to any more:
///
/// > **One table, replacing the two cards #2080 shipped.** Those cards existed
/// > to make the installed/downloadable boundary visible after ten rows, which a
/// > Source column does better: it aligns, it scans, and it does not split the
/// > list in half. Group ORDER is preserved — installed first — so
/// > `LivePreviewPackPresentation.groups(from:)` still owns the policy and its
/// > tests still mean something.
///
/// The boundary is now the FILTER, which does the same job in a place where it can also
/// be the default: this sheet opens on `Not on this Mac`, because acquiring is the only
/// reason to be here. `groups(from:)` still owns the policy and still supplies both counts.
///
/// Also carried, and still binding:
///
/// > No drag handles and no per-row overflow menu, both of which the mockup
/// > drew: nothing in the app orders languages, and Apple's packs are not ours
/// > to delete, so each would be a control with nothing behind it (founder,
/// > Gate 1).
struct LivePreviewPackCatalogSheet: View {
  @Environment(\.dismiss) private var dismiss

  /// **Owned by the WINDOW, not by this sheet.** The install workflow outlives any
  /// presentation: dismissing this sheet mid-download must not cancel it, which is why
  /// the model is passed in rather than created here.
  let packs: LivePreviewPacksModel

  /// The pack tag currently producing the preview, or nil.
  ///
  /// Resolved by the CALLER, which owns the two gates that decide whether "In use" is a
  /// claim we may make. Carried verbatim from `isActive`:
  ///
  /// > Gated on the toggle because "In use" is a claim about a running preview,
  /// > and nothing runs while the feature is off. Gated on the ENGINE because
  /// > these are Apple's packs: with the universal engine selected the badge would
  /// > name a language that is not the one on screen.
  let activeTag: String?

  /// Seeded by the status bar's remedy with the missing language's NAME, so the row a
  /// user was sent here for is already on screen. Empty from the Languages row, where
  /// there is no particular language in question.
  init(packs: LivePreviewPacksModel, activeTag: String?, initialSearch: String = "") {
    self.packs = packs
    self.activeTag = activeTag
    _searchText = State(initialValue: initialSearch)
  }

  /// View-local: a search box is about what this SHEET is showing, not about the
  /// catalogue, so the model has no reason to know it exists.
  @State private var searchText: String

  /// Which half of the catalogue is on screen. Not-installed first, because acquiring a
  /// language is the only reason this sheet opens.
  @State private var showingInstalled: Bool = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        header
        Divider().overlay(Color.stDivider)
        content
      }
      .frame(minWidth: 460, minHeight: 420)
      .background(Color.stPageBg)
      .navigationTitle(LivePreviewSettingsCopy.packsHeader)
      // **A failed read must be retryable, or the message is a dead end.**
      // `packsUnavailable` tells the user to reopen; nothing reloaded when they did,
      // so reopening produced the same failure forever. Only on `.failed`, so an
      // ordinary open does not re-read an inventory the page already has.
      .task {
        if case .failed = packs.state { await packs.load() }
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(LivePreviewSettingsCopy.catalogDoneButton) { dismiss() }
        }
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(LivePreviewSettingsCopy.packsDescription).settingsReadingCopy()

      // Only once there is a list to search: a search box over a spinner or over
      // the "could not read" message is a control that does nothing.
      if case .loaded = packs.state {
        searchField
        filterChips
      }
    }
    .padding(16)
  }

  /// Carried verbatim from the page's own search box, whose shape this keeps:
  ///
  /// > Same shape as `LanguageLockSheet.searchField`, deliberately: the app
  /// > already has a language search and a second visual idiom for the same job
  /// > would read as a different feature.
  ///
  /// The recessed-with-a-border treatment came from the same decision:
  ///
  /// > there because it spans the sheet's full width at the top. Inside a card
  /// > that underline reads as no container at all (founder, 2026-08-16).
  ///
  /// This IS a sheet now, so the underline would have been available again — kept as a
  /// bordered field anyway, because the third idiom for one job is the cost this comment
  /// was written to avoid.
  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.stTextSecondary)
      TextField(LivePreviewSettingsCopy.packsSearchPlaceholder, text: $searchText)
        .textFieldStyle(.plain)
        .accessibilityLabel("Search languages")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.stDivider, lineWidth: 1))
  }

  /// Both counts come from the SAME searched grouping the rows do, so a chip can never
  /// disagree with the list under it — including while a search is active, which is the
  /// case that shipped wrong for one review round.
  private var filterChips: some View {
    let groups = visibleGroups
    return HStack(spacing: 6) {
      chip(
        title: LivePreviewSettingsCopy.catalogFilterAvailable,
        count: groups.available.count, selected: !showingInstalled
      ) { showingInstalled = false }
      chip(
        title: LivePreviewSettingsCopy.catalogFilterInstalled,
        count: groups.installed.count, selected: showingInstalled
      ) { showingInstalled = true }
      Spacer(minLength: 0)
    }
  }

  private func chip(
    title: String, count: Int, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Text(title)
        Text("\(count)").opacity(0.65)
      }
      .font(.stHelper)
      .padding(.horizontal, 11)
      .padding(.vertical, 4)
      .background(
        selected ? Color.stAccentSolid : Color.clear,
        in: Capsule()
      )
      .foregroundStyle(selected ? Color.white : Color.stTextSecondary)
      .overlay(
        Capsule().strokeBorder(selected ? Color.clear : Color.stDivider, lineWidth: 1))
    }
    .buttonStyle(.plain)
    // **Which half is showing lives ONLY in these two colours**, so without this a
    // VoiceOver user hears two ordinary buttons with labels and counts and has no
    // way to tell which one the list below is obeying — on a sheet whose entire
    // job is "the languages you do NOT have". Cloud review on PR #2440.
    //
    // `.isSelected` rather than a "(selected)" suffix on the label: the trait is
    // what assistive tech reads as SELECTION, and baking the state into the visible
    // title would also change the button's own name every time it is pressed.
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch packs.state {
    case .loading:
      // `packsLoading`, NOT `packInstalling` — this spinner is a local inventory
      // read. The per-row spinner below is the one that means a transfer.
      centered {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(LivePreviewSettingsCopy.packsLoading).settingsHelperCopy()
        }
      }
    case .failed:
      centered { Text(LivePreviewSettingsCopy.packsUnavailable).settingsHelperCopy() }
    case .loaded:
      if visibleRows.isEmpty {
        // **An empty FILTER is not a failed SEARCH.** With every pack installed the
        // default half is empty and no query was typed, so blaming the search would
        // accuse the user of something they did not do.
        centered { Text(emptyMessage).settingsHelperCopy() }
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(visibleRows, id: \.id) { pack in
              packRow(pack)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
              Divider().overlay(Color.stDivider).padding(.leading, 16)
            }
          }
        }
      }
    }
  }

  private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack {
      Spacer()
      content()
      Spacer()
    }.frame(maxWidth: .infinity)
  }

  /// Which nothing-here message applies: the search found nothing, or this half of the
  /// catalogue is genuinely empty.
  private var emptyMessage: String {
    guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return LivePreviewSettingsCopy.packsNoSearchMatch
    }
    return showingInstalled
      ? LivePreviewSettingsCopy.catalogNoneInstalled
      : LivePreviewSettingsCopy.catalogNothingToInstall
  }

  private var loadedPacks: [LivePreviewPack] {
    guard case .loaded(let rows) = packs.state else { return [] }
    return rows
  }

  /// **One searched grouping feeds BOTH the chips and the rows.** Computing them
  /// separately is how the chips came to count the full catalogue while the rows showed
  /// only matches — a chip reading "Not on this Mac 53" above one row is worse than no
  /// chip. `groups(from:matching:)` owns the policy, so there is one answer to disagree
  /// with rather than two.
  private var visibleGroups: LivePreviewPackPresentation.Groups {
    LivePreviewPackPresentation.groups(from: loadedPacks, matching: searchText)
  }

  private var visibleRows: [LivePreviewPack] {
    showingInstalled ? visibleGroups.installed : visibleGroups.available
  }

  @ViewBuilder
  private func packRow(_ pack: LivePreviewPack) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(pack.localizedName).settingsRowLabel()
        if pack.nativeName != pack.localizedName {
          Text(pack.nativeName).settingsHelperCopy()
        }
        // The failure needs WORDS, not just a relabelled button. "Try again"
        // alone leaves the user guessing whether the download broke, whether
        // they did something wrong, or whether the language is unavailable — and
        // the remedy is the same for every cause, so one sentence answers all.
        if packs.failedTag == pack.tag {
          Text(LivePreviewSettingsCopy.packInstallFailed).settingsHelperCopy()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      statusCell(pack)
    }
  }

  @ViewBuilder
  private func statusCell(_ pack: LivePreviewPack) -> some View {
    if pack.tag == activeTag {
      // "Ready" says the bytes are here; it never said WHICH language you are
      // actually previewing in. With nine installed, that was the whole confusion.
      ProviderStatusChip(
        status: ProviderStatus(label: LivePreviewSettingsCopy.packInUse, tone: .ready))
    } else if pack.isInstalled {
      ProviderStatusChip(
        status: ProviderStatus(
          label: LivePreviewSettingsCopy.packInstalled, tone: .unavailable))
    } else if packs.installingTag == pack.tag {
      // A spinner, never a percentage. Apple's progress object yields two
      // distinct values across a whole install, so a bar would be a fabrication.
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(LivePreviewSettingsCopy.packInstalling).settingsHelperCopy()
      }
    } else {
      Button(
        packs.failedTag == pack.tag
          ? LivePreviewSettingsCopy.packRetry
          : LivePreviewSettingsCopy.packInstall
      ) {
        packs.install(tag: pack.tag)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(packs.installingTag != nil)
    }
  }
}
