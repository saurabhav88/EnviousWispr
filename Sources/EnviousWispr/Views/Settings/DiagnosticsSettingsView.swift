import SwiftUI

struct DiagnosticsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Debug Mode") {
                Toggle("Enable debug mode", isOn: $state.settings.isDebugModeEnabled)
                Text("Persists across relaunches. Toggle with Cmd+Shift+D from anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.settings.isDebugModeEnabled {
                    Picker("Log Level", selection: $state.settings.debugLogLevel) {
                        ForEach(DebugLogLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                }
            }

            Section("Log Files") {
                HStack {
                    Button("Open Log Directory") {
                        Task {
                            let url = await AppLogger.shared.logDirectoryURL()
                            NSWorkspace.shared.open(url)
                        }
                    }

                    Button("Copy Log Path") {
                        Task {
                            let url = await AppLogger.shared.logDirectoryURL()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.path, forType: .string)
                        }
                    }

                    Button("Clear Logs") {
                        Task {
                            try? await AppLogger.shared.clearLogs()
                        }
                    }
                    .foregroundStyle(.red)
                }

                Text("Logs are stored at ~/Library/Logs/EnviousWispr/. Maximum 10 MB per file, 5 files retained.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("OSLog") {
                Text("All log events are also sent to the macOS unified logging system. View them in Console.app by filtering for subsystem: com.enviouswispr.app")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Open Console.app") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
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
                    HStack {
                        Button("Run ASR Benchmark") {
                            Task { await appState.benchmark.run(using: appState.asrManager) }
                        }
                        Button("Run Pipeline Benchmark") {
                            Task { await appState.benchmark.runPipelineBenchmark(using: appState.asrManager) }
                        }
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

                if let pipeline = appState.benchmark.pipelineResult {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pipeline Benchmark Results")
                            .font(.caption).bold()
                        HStack {
                            Text("Batch ASR:")
                            Spacer()
                            Text(String(format: "%.3fs", pipeline.batchASRTime))
                                .monospacedDigit()
                        }.font(.caption)

                        if let streamTime = pipeline.streamingFinalizeTime {
                            HStack {
                                Text("Streaming finalize:")
                                Spacer()
                                Text(String(format: "%.3fs", streamTime))
                                    .monospacedDigit()
                            }.font(.caption)
                        }

                        if let wer = pipeline.werDelta {
                            HStack {
                                Text("Streaming vs Batch WER:")
                                Spacer()
                                Text(String(format: "%.1f%%", wer * 100))
                                    .monospacedDigit()
                                    .foregroundStyle(wer <= 0.02 ? .green : .orange)
                            }.font(.caption)
                        }

                        HStack {
                            Text("Audio duration:")
                            Spacer()
                            Text(String(format: "%.1fs", pipeline.audioDuration))
                                .monospacedDigit()
                        }.font(.caption)
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
