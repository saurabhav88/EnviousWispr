import EnviousWisprServices
import SwiftUI

/// Clipboard behavior settings.
struct ClipboardSettingsView: View {
  @Environment(SettingsManager.self) private var settings

  var body: some View {
    @Bindable var settings = settings

    SettingsContentView {
      BrandedSection(header: "Clipboard") {
        BrandedRow {
          Toggle("Auto-copy to clipboard", isOn: $settings.autoCopyToClipboard)
            .toggleStyle(BrandedToggleStyle())
        }
        BrandedRow(showDivider: false) {
          VStack(alignment: .leading, spacing: 4) {
            Toggle(
              "Restore clipboard after paste", isOn: $settings.restoreClipboardAfterPaste
            )
            .toggleStyle(BrandedToggleStyle())
            Text("Saves and restores whatever was on your clipboard before pasting the transcript.")
              .font(.stHelper)
              .foregroundStyle(.stTextTertiary)
          }
        }
      } footer: {
        FrozenPerRecordingFootnote()
      }
    }
  }
}
