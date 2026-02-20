import SwiftUI

struct DiagnosticsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Debug Mode") {
                Toggle("Enable debug mode", isOn: $state.settings.isDebugModeEnabled)
                Text("Resets to off on next launch. Toggle with Cmd+Shift+D from anywhere.")
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
        }
        .formStyle(.grouped)
        .padding()
    }
}
