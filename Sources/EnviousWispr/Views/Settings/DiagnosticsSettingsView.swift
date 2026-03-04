import SwiftUI

struct DiagnosticsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        SettingsContentView {
            // ── Debug Mode ────────────────────────────────────────────────────
            BrandedSection(header: "Debug Mode") {
                BrandedRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Enable debug mode", isOn: $state.settings.isDebugModeEnabled)
                            .toggleStyle(BrandedToggleStyle())
                        Text("Persists across relaunches. Toggle with Cmd+Shift+D from anywhere.")
                            .font(.stHelper)
                            .foregroundStyle(.stTextTertiary)
                    }
                }
                if appState.settings.isDebugModeEnabled {
                    BrandedRow {
                        Picker("Log Level", selection: $state.settings.debugLogLevel) {
                            ForEach(DebugLogLevel.allCases, id: \.self) { level in
                                Text(level.displayName).tag(level)
                            }
                        }
                    }
                    BrandedRow(showDivider: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            Button("Restart Onboarding…") {
                                appState.settings.onboardingState = .notStarted
                                if let delegate = NSApp.delegate as? AppDelegate {
                                    delegate.openOnboardingWindow()
                                }
                            }
                            .disabled(appState.pipelineState != .idle)
                            Text("Re-runs the onboarding flow without wiping app state. Disabled during recording.")
                                .font(.stHelper)
                                .foregroundStyle(.stTextTertiary)
                        }
                    }
                }
            }

            // ── Log Files ─────────────────────────────────────────────────────
            BrandedSection(header: "Log Files") {
                BrandedRow {
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
                }
                BrandedRow(showDivider: false) {
                    Text("Logs are stored at ~/Library/Logs/EnviousWispr/. Maximum 10 MB per file, 5 files retained.")
                        .font(.stHelper)
                        .foregroundStyle(.stTextTertiary)
                }
            }

            // ── OSLog ─────────────────────────────────────────────────────────
            BrandedSection(header: "OSLog") {
                BrandedRow {
                    Text("All log events are also sent to the macOS unified logging system. View them in Console.app by filtering for subsystem: com.enviouswispr.app")
                        .font(.stHelper)
                        .foregroundStyle(.stTextTertiary)
                }
                BrandedRow(showDivider: false) {
                    Button("Open Console.app") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
                    }
                }
            }

            // ── Performance ───────────────────────────────────────────────────
            BrandedSection(header: "Performance") {
                if appState.benchmark.isRunning {
                    BrandedRow {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text(appState.benchmark.progress)
                                .font(.caption)
                        }
                    }
                } else {
                    BrandedRow {
                        HStack {
                            Button("Run ASR Benchmark") {
                                Task { await appState.benchmark.run(using: appState.asrManager) }
                            }
                            Button("Run Pipeline Benchmark") {
                                Task { await appState.benchmark.runPipelineBenchmark(using: appState.asrManager) }
                            }
                        }
                    }
                }

                if !appState.benchmark.results.isEmpty {
                    BrandedRow {
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
                }

                if let pipeline = appState.benchmark.pipelineResult {
                    BrandedRow {
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
                }

                BrandedRow(showDivider: false) {
                    HStack {
                        Text("Model status:")
                        Spacer()
                        Text(appState.asrManager.isModelLoaded ? "Loaded" : "Unloaded")
                            .foregroundStyle(appState.asrManager.isModelLoaded ? .green : .secondary)
                    }
                }
            }
        }
    }
}
