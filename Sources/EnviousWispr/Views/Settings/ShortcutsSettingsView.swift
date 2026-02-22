import SwiftUI

/// Global hotkey configuration and reference.
struct ShortcutsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Global Hotkey") {
                Toggle("Enable global hotkey", isOn: $state.settings.hotkeyEnabled)
            }

            if appState.settings.hotkeyEnabled {
                Section("Recording Shortcuts") {
                    // Toggle mode hotkey
                    HotkeyRecorderView(
                        keyCode: $state.settings.toggleKeyCode,
                        modifiers: $state.settings.toggleModifiers,
                        defaultKeyCode: 49,  // Space
                        defaultModifiers: .control,
                        label: "Toggle recording"
                    )

                    Text("Press this shortcut to start/stop recording in toggle mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    // Push-to-talk key combo
                    HotkeyRecorderView(
                        keyCode: $state.settings.pushToTalkKeyCode,
                        modifiers: $state.settings.pushToTalkModifiers,
                        defaultKeyCode: 49,  // Space
                        defaultModifiers: .option,
                        label: "Push-to-talk"
                    )

                    Text("Hold this key combo to record, release to stop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    // Cancel hotkey
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

                Section("Current Mode") {
                    HStack {
                        Text("Active mode:")
                        Spacer()
                        Text(appState.settings.recordingMode == .toggle ? "Toggle" : "Push-to-Talk")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Active hotkey:")
                        Spacer()
                        Text(appState.hotkeyService.hotkeyDescription)
                            .font(.system(.body, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
                    }

                    Text("Change recording mode in Speech Engine settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Hotkey Reference") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Open window:")
                            .font(.caption)
                        Spacer()
                        Text("⌘O (from menu bar)")
                            .font(.caption.monospaced())
                    }
                    HStack {
                        Text("Settings:")
                            .font(.caption)
                        Spacer()
                        Text("⌘, (from menu bar)")
                            .font(.caption.monospaced())
                    }
                    HStack {
                        Text("Quit:")
                            .font(.caption)
                        Spacer()
                        Text("⌘Q")
                            .font(.caption.monospaced())
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
