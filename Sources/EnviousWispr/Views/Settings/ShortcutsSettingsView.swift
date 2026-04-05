import SwiftUI

/// Global hotkey configuration.
struct ShortcutsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        SettingsContentView {
            BrandedSection(header: "Transcribe Shortcut") {
                BrandedRow {
                    HotkeyRecorderView(
                        keyCode: $state.settings.toggleKeyCode,
                        modifiers: $state.settings.toggleModifiers,
                        defaultKeyCode: 49,
                        defaultModifiers: .control,
                        label: "Shortcut"
                    )
                }
                BrandedRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            appState.settings.isPushToTalk ? "Push to Talk" : "Toggle",
                            isOn: $state.settings.isPushToTalk
                        )
                        .toggleStyle(BrandedToggleStyle())
                        Text(appState.settings.isPushToTalk
                             ? "Hold the hotkey to record, release to stop."
                             : "Press the hotkey to start recording, press again to stop.")
                            .font(.stHelper)
                            .foregroundStyle(.stTextTertiary)
                        if appState.settings.isPushToTalk {
                            Text("Double-press to go hands-free. Triple-press to cancel.")
                                .font(.stHelper)
                                .foregroundStyle(.stTextTertiary.opacity(0.72))
                        }
                    }
                }
                BrandedRow {
                    HotkeyRecorderView(
                        keyCode: $state.settings.cancelKeyCode,
                        modifiers: $state.settings.cancelModifiers,
                        defaultKeyCode: 53,
                        defaultModifiers: [],
                        label: "Cancel recording"
                    )
                }
                BrandedRow(showDivider: false) {
                    Text("Press this to discard the current recording and return to idle.")
                        .font(.stHelper)
                        .foregroundStyle(.stTextTertiary)
                }
            }
        }
    }
}
