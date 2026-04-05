import SwiftUI

/// Clipboard behavior settings.
struct ClipboardSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        SettingsContentView {
            BrandedSection(header: "Clipboard") {
                BrandedRow {
                    Toggle("Auto-copy to clipboard", isOn: $state.settings.autoCopyToClipboard)
                        .toggleStyle(BrandedToggleStyle())
                }
                BrandedRow(showDivider: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Restore clipboard after paste", isOn: $state.settings.restoreClipboardAfterPaste)
                            .toggleStyle(BrandedToggleStyle())
                        Text("Saves and restores whatever was on your clipboard before pasting the transcript.")
                            .font(.stHelper)
                            .foregroundStyle(.stTextTertiary)
                    }
                }
            }
        }
    }
}
