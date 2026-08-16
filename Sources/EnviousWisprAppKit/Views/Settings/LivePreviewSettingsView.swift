import EnviousWisprLivePreview
import EnviousWisprServices
import SwiftUI

/// The Live Preview settings page (#2080).
///
/// Moved out of Transcription, where it was a sub-section of a page about something else and
/// nobody found it. With a page of its own there is room for the thing that actually decides
/// whether the feature works for a given user: which of Apple's language packs their Mac has.
///
/// Measured, and the reason this page exists: exactly 7 of 54 languages are installed on a stock
/// Mac, and the set is not regional. A French, Italian, Korean, Portuguese, Dutch, Russian or
/// Polish user previously got an empty pill and no way to learn why.
struct LivePreviewSettingsView: View {
  /// Narrow environment home, matching every sibling settings page.
  @Environment(SettingsManager.self) private var settings

  /// **Owned by the WINDOW, not by this page.** Selecting another sidebar section destroys this
  /// view, and with it any `@State` it owned — so a download in flight lost its bookkeeping and a
  /// returning user could start a second one. `swiftui-mv-first` puts cross-view state in the
  /// retained parent, and `swiftui-task-never-owns-workflows` says a multi-second workflow like a
  /// download must outlive view churn. This page only renders it.
  let packs: LivePreviewPacksModel

  /// View-local too: a search box is about what this page is SHOWING, not about the catalogue,
  /// so the model has no reason to know it exists.
  @State private var searchText: String = ""

  private var isSupported: Bool { ApplePreviewEngineResolver.isSupportedOnThisSystem }

  /// The toggle's own value, NOT whether a preview could run. Anything the page says about a live
  /// preview is false while this is off, and it is off by default.
  private var isPreviewOn: Bool { settings.livePreviewEnabled }

  var body: some View {
    @Bindable var settings = settings
    return SettingsContentView {
      BrandedSection(header: LivePreviewSettingsCopy.sectionHeader) {
        BrandedRow(showDivider: false) {
          HStack(alignment: .top, spacing: 11) {
            SettingsRowIcon(systemName: "text.viewfinder")
            VStack(alignment: .leading, spacing: 4) {
              Toggle(isOn: $settings.livePreviewEnabled) {
                Text(LivePreviewSettingsCopy.toggleLabel).settingsRowLabel()
              }
              .toggleStyle(BrandedToggleStyle())
              .disabled(!isSupported)
              Text(LivePreviewSettingsCopy.toggleDescription)
                .settingsReadingCopy()
              if !isSupported {
                Text(LivePreviewSettingsCopy.needsNewerMacOS)
                  .settingsReadingCopy()
              }
            }
          }
        }
      }

      // The question the page exists to answer, before any inventory: which language will my
      // words appear in right now. A list of 54 rows never said, so nine installed languages told
      // the user nothing about which one was live.
      //
      // **Only while the preview is actually on.** The toggle defaults to OFF, so without this
      // gate the DEFAULT state of the page announced "Your words will appear in English" and
      // marked a row "In use" for something that cannot run — a status that is not merely stale
      // but false. Switching the toggle on reveals it, which also makes the section read as a
      // consequence of the toggle above it. The list below stays visible either way, so a pack
      // can still be downloaded before turning the feature on.
      if isSupported, isPreviewOn, let active = packs.active {
        BrandedSection(header: LivePreviewSettingsCopy.activeHeader) {
          BrandedRow(showDivider: false) {
            VStack(alignment: .leading, spacing: 10) {
              activeSummary(active)
              // `InsetNotice` is the app's existing idiom for a quiet explanation inside a card.
              // Always visible rather than behind a disclosure: the whole problem was not knowing
              // where the language comes from, and an explanation you must first discover does
              // not solve that.
              InsetNotice(text: LivePreviewSettingsCopy.activeExplainer)
            }
          }
        }
      }

      // Hidden entirely below macOS 26: there are no Apple packs to manage, and an empty list
      // under a disabled toggle would read as something being broken.
      if isSupported {
        BrandedSection(header: LivePreviewSettingsCopy.packsHeader) {
          BrandedRow(showDivider: false) {
            VStack(alignment: .leading, spacing: 10) {
              Text(LivePreviewSettingsCopy.packsDescription).settingsReadingCopy()
              // Only once there is a list to search: offering a search box over a spinner or over
              // the "could not read" message would be a control that does nothing.
              if case .loaded = packs.state { searchField }
            }
          }
          // The non-list states stay inside this card; the two groups become cards of their own.
          nonListState
        }
        packSections
      }
    }
    // **Keyed on the language, not merely on appearance.**
    //
    // A plain `.task` runs once per appearance, and the dictation language can change while this
    // page stays open: the passive suggestion chip locks a language straight into settings
    // (`WisprBootstrapper`), and so does the language sheet. The summary would then describe the
    // new mode while the resolved language and the "In use" badge still named the old one — the
    // page contradicting itself in two places at once.
    //
    // Keyed on the VALUE rather than wired to those two call sites, so a third writer added later
    // is covered without knowing this page exists. `swiftui-view-patterns.md`
    // RULE: swiftui-task-id-cancellation is the house rule for exactly this.
    .task(id: settings.languageMode) {
      guard isSupported else { return }
      // Re-read on EVERY appearance. The model outlives this page now, so without this a
      // returning user would see the snapshot from whenever they last opened it — past a download
      // that finished meanwhile, past a macOS purge of a staged asset. The catalogue exists
      // precisely because this state is not ours to cache.
      // Hand over the live setting, not its value: a download that finishes after the user
      // changes the dictation language must answer for the language they have now.
      packs.useMode { settings.languageMode }
      await packs.load()
    }
  }

  /// States the resolved language plainly, and where it came from, so "what is active" is
  /// readable without inferring it from the list.
  @ViewBuilder
  private func activeSummary(_ active: LivePreviewPacksModel.ActiveLanguage) -> some View {
    HStack(alignment: .top, spacing: 11) {
      SettingsRowIcon(systemName: "waveform")
      VStack(alignment: .leading, spacing: 4) {
        switch active {
        case .ready(_, let name):
          Text(LivePreviewSettingsCopy.activeReady(name)).settingsRowLabel()
          Text(LivePreviewSettingsCopy.activeSource(settings.languageMode))
            .settingsHelperCopy()
        case .needsDownload(let name):
          Text(LivePreviewSettingsCopy.activeNeedsDownload(name)).settingsRowLabel()
          Text(LivePreviewSettingsCopy.activeNeedsDownloadHelp).settingsHelperCopy()
        case .unsupportedLanguage:
          Text(LivePreviewSettingsCopy.activeUnsupportedLanguage).settingsRowLabel()
          Text(LivePreviewSettingsCopy.activeUnsupportedLanguageHelp).settingsHelperCopy()
        case .unsupportedSystem:
          Text(LivePreviewSettingsCopy.needsNewerMacOS).settingsReadingCopy()
        }
      }
      Spacer(minLength: 8)
    }
  }

  /// Same shape as `LanguageLockSheet.searchField`, deliberately: the app already has a language
  /// search and a second visual idiom for the same job would read as a different feature.
  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.stTextSecondary)
      TextField(LivePreviewSettingsCopy.packsSearchPlaceholder, text: $searchText)
        .textFieldStyle(.plain)
        .accessibilityLabel("Search languages")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    // Recessed surface WITH a border, matching `InsetNotice` on this same page.
    //
    // The sheet this was ported from underlines its field instead, which works there because it
    // spans the sheet's full width at the top. Inside a card that underline reads as no container
    // at all — the field looked like loose text floating on the card (founder, 2026-08-16). The
    // port took the background and left the edge treatment behind, which is the same partial-copy
    // mistake that produced the reservation defect earlier in this branch.
    .background(Color.stPageBg, in: RoundedRectangle(cornerRadius: 9))
    .overlay(
      RoundedRectangle(cornerRadius: 9).strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }

  /// Loading, unreadable, or nothing matching the search — states that belong with the intro
  /// rather than under a group heading.
  @ViewBuilder
  private var nonListState: some View {
    switch packs.state {
    case .loading:
      BrandedRow(showDivider: false) {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          // `packsLoading`, NOT `packInstalling` — this spinner is a local inventory read.
          // The per-row spinner below is the one that means a transfer.
          Text(LivePreviewSettingsCopy.packsLoading).settingsHelperCopy()
        }
      }
    case .failed:
      BrandedRow(showDivider: false) {
        Text(LivePreviewSettingsCopy.packsUnavailable).settingsHelperCopy()
      }
    case .loaded:
      if visibleGroups.isEmpty {
        BrandedRow(showDivider: false) {
          Text(LivePreviewSettingsCopy.packsNoSearchMatch).settingsHelperCopy()
        }
      }
    }
  }

  /// **Each group is its own card.** As rows inside one card the headings carried the same weight
  /// as a language name and vanished between them, so after ten rows there was no visible boundary
  /// between what is installed and what is a download away (founder, 2026-08-16). A section header
  /// is the app's existing way to separate groups, and two cards make the split unmissable.
  @ViewBuilder
  private var packSections: some View {
    let groups = visibleGroups
    if !groups.installed.isEmpty {
      BrandedSection(header: LivePreviewPackPresentation.installedGroupTitle) {
        packRows(groups.installed)
      }
    }
    if !groups.available.isEmpty {
      BrandedSection(header: LivePreviewPackPresentation.availableGroupTitle) {
        packRows(groups.available)
      }
    }
  }

  /// Search first, then group: filtering a grouped list would have to re-derive the split, and a
  /// group emptied by the filter must not render an empty card.
  private var visibleGroups: LivePreviewPackPresentation.Groups {
    guard case .loaded(let rows) = packs.state else {
      return LivePreviewPackPresentation.groups(from: [])
    }
    return LivePreviewPackPresentation.groups(
      from: LivePreviewPackPresentation.matching(rows, query: searchText))
  }

  @ViewBuilder
  private func packRows(_ packsToShow: [LivePreviewPack]) -> some View {
    ForEach(Array(packsToShow.enumerated()), id: \.element.id) { index, pack in
      BrandedRow(showDivider: index < packsToShow.count - 1) {
        packRow(pack)
      }
    }
  }

  /// Gated on the toggle for the same reason the section above is: "In use" is a claim about a
  /// running preview, and nothing runs while the feature is off. The badge and the section read
  /// the same `isPreviewOn`, so they cannot disagree about whether a language is live.
  private func isActive(_ pack: LivePreviewPack) -> Bool {
    guard isPreviewOn, case .ready(let tag, _) = packs.active else { return false }
    return tag == pack.tag
  }

  @ViewBuilder
  private func packRow(_ pack: LivePreviewPack) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(pack.localizedName).settingsRowLabel()
        if pack.nativeName != pack.localizedName {
          Text(pack.nativeName).settingsHelperCopy()
        }
        // The failure needs WORDS, not just a relabelled button. "Try again" alone leaves the
        // user guessing whether the download broke, whether they did something wrong, or whether
        // the language is unavailable — and the remedy (check the connection) is the same for
        // every cause, so one sentence answers all of them. This string existed and was never
        // rendered anywhere; a copy test referencing it made it look wired when it was not.
        if packs.failedTag == pack.tag {
          Text(LivePreviewSettingsCopy.packInstallFailed).settingsHelperCopy()
        }
      }
      Spacer(minLength: 8)

      if isActive(pack) {
        // "Ready" says the bytes are here; it never said WHICH language you are actually
        // previewing in. With nine installed, that was the whole confusion.
        Text(LivePreviewSettingsCopy.packInUse)
          .settingsRowLabel()
      } else if pack.isInstalled {
        Text(LivePreviewSettingsCopy.packInstalled)
          .settingsHelperCopy()
      } else if packs.installingTag == pack.tag {
        // A spinner, never a percentage. Apple's progress object yields two distinct values
        // across a whole install, so a bar would be a fabrication.
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

}
