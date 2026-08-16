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
            Text(LivePreviewSettingsCopy.packsDescription).settingsReadingCopy()
          }
          packsContent
        }
      }
    }
    .task {
      guard isSupported, packs == nil else { return }
      let model = LivePreviewPacksModel(catalog: makeCatalog())
      packs = model
      await model.load()
    }
    .onDisappear {
      // Explicit, because `deinit` is backup only: the install task captures the model weakly
      // precisely so it cannot keep the page alive.
      packs?.cancelInstall()
    }
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
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, pack in
        BrandedRow(showDivider: index < rows.count - 1) {
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
