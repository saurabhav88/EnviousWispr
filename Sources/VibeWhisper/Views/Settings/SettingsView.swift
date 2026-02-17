import SwiftUI

/// App settings view (basic version for M0, expanded in M2/M3).
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            // TODO: M2 — Hotkey settings tab
            // TODO: M3 — LLM settings tab
            // TODO: M3 — Privacy settings tab
        }
        .frame(width: 450, height: 300)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("ASR Backend") {
                Picker("Backend", selection: $state.selectedBackend) {
                    Text("Parakeet v3 (Primary)").tag(ASRBackendType.parakeet)
                    Text("WhisperKit (Fallback)").tag(ASRBackendType.whisperKit)
                }
                .pickerStyle(.segmented)
            }

            Section("Recording") {
                Picker("Mode", selection: $state.recordingMode) {
                    Text("Push to Talk").tag(RecordingMode.pushToTalk)
                    Text("Toggle").tag(RecordingMode.toggle)
                }
            }

            Section("Behavior") {
                Toggle("Auto-copy to clipboard", isOn: $state.autoCopyToClipboard)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
