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

            Section("Recording") {
                Picker("Mode", selection: $state.settings.recordingMode) {
                    Text("Push to Talk").tag(RecordingMode.pushToTalk)
                    Text("Toggle").tag(RecordingMode.toggle)
                }
            }

            Section("Performance") {
                if appState.benchmark.isRunning {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(appState.benchmark.progress)
                            .font(.caption)
                    }
                } else {
                    Button("Run Benchmark") {
                        Task { await appState.benchmark.run(using: appState.asrManager) }
                    }
                }

                if !appState.benchmark.results.isEmpty {
                    ForEach(appState.benchmark.results) { result in
                        HStack {
                            Text(result.label)
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2fs", result.processingTime))
                                .font(.caption)
                                .monospacedDigit()
                            Text(String(format: "%.0fx RT", result.rtf))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                HStack {
                    Text("Model status:")
                    Spacer()
                    Text(appState.asrManager.isModelLoaded ? "Loaded" : "Unloaded")
                        .foregroundStyle(appState.asrManager.isModelLoaded ? .green : .secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
