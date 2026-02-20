import SwiftUI

/// Clipboard behavior settings.
struct ClipboardSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Clipboard") {
                Toggle("Auto-copy to clipboard", isOn: $state.settings.autoCopyToClipboard)
                Toggle("Restore clipboard after paste", isOn: $state.settings.restoreClipboardAfterPaste)
                Text("Saves and restores whatever was on your clipboard before pasting the transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
