import SwiftUI

/// Global hotkey configuration and reference.
struct ShortcutsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Global Hotkey") {
                Toggle("Enable global hotkey", isOn: $state.hotkeyEnabled)

                if appState.hotkeyEnabled {
                    HStack {
                        Text("Current hotkey:")
                        Spacer()
                        Text(appState.hotkeyService.hotkeyDescription)
                            .font(.system(.body, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
                    }

                    if appState.recordingMode == .toggle {
                        Text("Press ⌃Space to toggle recording on/off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Hold ⌥Option to record, release to stop.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !appState.permissions.hasAccessibilityPermission {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Accessibility permission required for global hotkey.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Enable") {
                            appState.permissions.promptAccessibilityPermission()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Hotkey Reference") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Toggle mode:")
                            .font(.caption)
                        Spacer()
                        Text("⌃Space")
                            .font(.caption.monospaced())
                    }
                    HStack {
                        Text("Push-to-talk:")
                            .font(.caption)
                        Spacer()
                        Text("Hold ⌥Option")
                            .font(.caption.monospaced())
                    }
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
                        Text("Cancel recording:")
                            .font(.caption)
                        Spacer()
                        Text("Escape")
                            .font(.caption.monospaced())
                    }
                }
            }

            Section("Cancel Hotkey") {
                HStack {
                    Text("Cancel recording:")
                    Spacer()
                    Text(appState.hotkeyService.cancelHotkeyDescription)
                        .font(.system(.body, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
                }
                Text("Press this key while recording to immediately discard audio and return to idle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
