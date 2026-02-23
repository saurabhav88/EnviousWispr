import SwiftUI

/// ASR backend, recording mode, and benchmark settings.
struct SpeechEngineSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("ASR Backend") {
                Picker("Backend", selection: $state.settings.selectedBackend) {
                    Text("Parakeet v3 (Primary)").tag(ASRBackendType.parakeet)
                    Text("WhisperKit (Fallback)").tag(ASRBackendType.whisperKit)
                }
                .pickerStyle(.segmented)

                if appState.settings.selectedBackend == .parakeet {
                    Text("Fast English transcription with built-in punctuation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Broader language support. No built-in punctuation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if appState.settings.selectedBackend == .whisperKit {
                    Picker("Model Quality", selection: $state.settings.whisperKitModel) {
                        Text("Base (Fast, Lower Quality)").tag("base")
                        Text("Small (Balanced)").tag("small")
                        Text("Large v3 (Best Quality)").tag("large-v3")
                    }
                    Text("Larger models produce better transcription but require more download time and memory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Voice Activity Detection") {
                Toggle("Auto-stop on silence", isOn: $state.settings.vadAutoStop)

                if appState.settings.vadAutoStop {
                    HStack {
                        Text("Silence timeout")
                        Slider(value: $state.settings.vadSilenceTimeout, in: 0.5...3.0, step: 0.25)
                        Text(String(format: "%.1fs", appState.settings.vadSilenceTimeout))
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 30)
                    }

                    Text("Recording stops automatically after this duration of silence following speech.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("VAD Sensitivity")
                    Slider(value: $state.settings.vadSensitivity, in: 0.0...1.0, step: 0.1)
                    Text(vadSensitivityLabel(appState.settings.vadSensitivity))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 55)
                }
                Text("Higher sensitivity detects quieter speech but may pick up background noise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Energy pre-gate", isOn: $state.settings.vadEnergyGate)
                if appState.settings.vadEnergyGate {
                    Text("Skips neural VAD for very quiet audio. Saves CPU during silence-heavy recordings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func vadSensitivityLabel(_ value: Float) -> String {
        switch value {
        case 0.0..<0.3: return "Low"
        case 0.3..<0.7: return "Medium"
        default:         return "High"
        }
    }
}
