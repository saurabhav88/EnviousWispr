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
          Toggle(isOn: $settings.autoCopyToClipboard) {
            HStack(spacing: 11) {
              SettingsRowIcon(systemName: "doc.on.clipboard")
              Text("Auto-copy to clipboard").settingsRowLabel()
            }
          }
          .toggleStyle(BrandedToggleStyle())
        }
        BrandedRow {
          HStack(alignment: .top, spacing: 11) {
            SettingsRowIcon(systemName: "arrow.uturn.backward")
            VStack(alignment: .leading, spacing: 4) {
              Toggle(isOn: $settings.restoreClipboardAfterPaste) {
                Text("Restore clipboard after paste").settingsRowLabel()
              }
              .toggleStyle(BrandedToggleStyle())
              Text(
                "Saves and restores whatever was on your clipboard before pasting the transcript."
              )
              .settingsReadingCopy()
            }
          }
        }
        BrandedRow(showDivider: false) {
          HStack(alignment: .top, spacing: 11) {
            SettingsRowIcon(systemName: "text.cursor")
            VStack(alignment: .leading, spacing: 4) {
              Toggle(isOn: $settings.smartInsertion) {
                Text("Smart insertion").settingsRowLabel()
              }
              .toggleStyle(BrandedToggleStyle())
              Text(
                "Matches spacing and capitalisation to the text around your cursor when you dictate into the middle of a sentence."
              )
              .settingsReadingCopy()
            }
          }
        }
      } footer: {
        FrozenPerRecordingFootnote()
      }
    }
  }
}
