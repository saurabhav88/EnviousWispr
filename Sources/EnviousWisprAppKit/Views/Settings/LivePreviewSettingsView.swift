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

  /// View-local, matching `CustomWordsImportSheet`'s shape: the model's lifetime is the page's.
  @State private var packs: LivePreviewPacksModel?

  /// View-local too: a search box is about what this page is SHOWING, not about the catalogue,
  /// so the model has no reason to know it exists.
  @State private var searchText: String = ""

  private var isSupported: Bool { ApplePreviewEngineResolver.isSupportedOnThisSystem }

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

      // Hidden entirely below macOS 26: there are no Apple packs to manage, and an empty list
      // under a disabled toggle would read as something being broken.
      if isSupported {
        BrandedSection(header: LivePreviewSettingsCopy.packsHeader) {
          BrandedRow(showDivider: false) {
            VStack(alignment: .leading, spacing: 10) {
              Text(LivePreviewSettingsCopy.packsDescription).settingsReadingCopy()
              // Only once there is a list to search: offering a search box over a spinner or over
              // the "could not read" message would be a control that does nothing.
              if case .loaded = packs?.state { searchField }
            }
          }
          packsContent
        }
      }
    }
    .task {
      guard isSupported else { return }
      // Re-read on EVERY appearance, not only the first. The settings window is retained when
      // closed, so a page that loaded once would keep showing that snapshot for the life of the
      // app — past a download that finished in the background, past a macOS purge of a staged
      // asset, past anything changed in System Settings. The catalogue exists precisely because
      // this state is not ours to cache.
      let model = packs ?? LivePreviewPacksModel(catalog: makeCatalog())
      packs = model
      await model.load()
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
    .background(Color.stSectionBg)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private var packsContent: some View {
    switch packs?.state {
    case .none, .loading:
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
    case .loaded(let rows):
      // Search first, then group: filtering a grouped list would have to re-derive the split, and
      // an empty group after filtering must not print a heading over nothing.
      let groups = LivePreviewPackPresentation.groups(
        from: LivePreviewPackPresentation.matching(rows, query: searchText))
      if groups.isEmpty {
        BrandedRow(showDivider: false) {
          Text(LivePreviewSettingsCopy.packsNoSearchMatch).settingsHelperCopy()
        }
      } else {
        packGroup(LivePreviewPackPresentation.installedGroupTitle, groups.installed)
        packGroup(LivePreviewPackPresentation.availableGroupTitle, groups.available)
      }
    }
  }

  /// One heading plus its rows, or nothing at all when the group is empty — a heading over an
  /// empty group reads as something having failed to load.
  @ViewBuilder
  private func packGroup(_ title: String, _ packs: [LivePreviewPack]) -> some View {
    if !packs.isEmpty {
      BrandedRow(showDivider: false) {
        HStack {
          Text(title).settingsRowLabel()
          Spacer()
        }
      }
      ForEach(Array(packs.enumerated()), id: \.element.id) { index, pack in
        BrandedRow(showDivider: index < packs.count - 1) {
          packRow(pack)
        }
      }
    }
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
        if packs?.failedTag == pack.tag {
          Text(LivePreviewSettingsCopy.packInstallFailed).settingsHelperCopy()
        }
      }
      Spacer(minLength: 8)

      if pack.isInstalled {
        Text(LivePreviewSettingsCopy.packInstalled)
          .settingsHelperCopy()
      } else if packs?.installingTag == pack.tag {
        // A spinner, never a percentage. Apple's progress object yields two distinct values
        // across a whole install, so a bar would be a fabrication.
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text(LivePreviewSettingsCopy.packInstalling).settingsHelperCopy()
        }
      } else {
        Button(
          packs?.failedTag == pack.tag
            ? LivePreviewSettingsCopy.packRetry
            : LivePreviewSettingsCopy.packInstall
        ) {
          packs?.install(tag: pack.tag)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(packs?.installingTag != nil)
      }
    }
  }

  private func makeCatalog() -> ApplePackCatalog {
    if #available(macOS 26.0, *) {
      return ApplePackCatalog(dependencies: .live)
    }
    // Unreachable: the caller gates on `isSupported`. Kept total rather than force-unwrapping a
    // version check, and an empty catalogue renders the honest "could not read" state.
    return ApplePackCatalog(
      dependencies: .init(
        supportedTags: { [] }, installedTags: { [] },
        reserve: { _ in }, release: { _ in }, install: { _ in }))
  }
}
