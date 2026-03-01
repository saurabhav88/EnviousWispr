import SwiftUI

/// Global hotkey configuration.
struct ShortcutsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Transcribe Shortcut") {
                HotkeyRecorderView(
                    keyCode: $state.settings.toggleKeyCode,
                    modifiers: $state.settings.toggleModifiers,
                    defaultKeyCode: 49,  // Space
                    defaultModifiers: .control,
                    label: "Shortcut"
                )

                Toggle(
                    appState.settings.isPushToTalk ? "Push to Talk" : "Toggle",
                    isOn: $state.settings.isPushToTalk
                )

                Text(appState.settings.isPushToTalk
                     ? "Hold the hotkey to record, release to stop."
                     : "Press the hotkey to start recording, press again to stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                HotkeyRecorderView(
                    keyCode: $state.settings.cancelKeyCode,
                    modifiers: $state.settings.cancelModifiers,
                    defaultKeyCode: 53,  // Escape
                    defaultModifiers: [],
                    label: "Cancel recording"
                )

                Text("Press this to discard the current recording and return to idle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
