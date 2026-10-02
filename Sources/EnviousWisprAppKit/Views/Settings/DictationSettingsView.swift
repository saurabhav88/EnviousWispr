import SwiftUI

/// Dictation Settings (#3385): one page whose six tabs hold what Transcription,
/// Microphone, Live Preview, Sounds and Clipboard held, plus the recording pill
/// from Appearance. Only the chosen tab's content exists; switching tabs builds
/// the new one and lets the old one go, exactly as switching sidebar pages did.
/// Work that must outlive a tab (a model or language download) is owned above
/// this view: `packs` is the window's own model, passed straight through.
struct DictationSettingsView: View {
  @Binding var selection: DictationTab
  let packs: LivePreviewPacksModel

  var body: some View {
    VStack(spacing: 0) {
      SettingsTabStrip(
        items: DictationTab.allCases.map {
          SettingsTabItem(id: $0, icon: $0.icon, label: $0.label)
        },
        selection: $selection
      )
      .padding(.horizontal, SettingsLayout.contentH - 4)
      .padding(.top, SettingsLayout.contentTop - 6)

      // Each tab keeps its own page's scroll view, so no outer one here.
      tabContent
        // The tabs replace the page-header card; the header path itself is
        // removed for every page later in #3385.
        .environment(\.settingsPageSection, nil)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.stPageBg)
  }

  @ViewBuilder
  private var tabContent: some View {
    switch selection {
    case .engine: SpeechEngineSettingsView()
    case .microphone: AudioSettingsView()
    case .livePreview: LivePreviewSettingsView(packs: packs)
    case .pill: PillSettingsView()
    case .chimes: RecordingSoundsSettingsView()
    case .clipboard: ClipboardSettingsView()
    }
  }
}
