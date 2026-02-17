import SwiftUI

/// Primary transcript window.
struct MainWindowView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            // Sidebar: transcript history
            TranscriptHistoryView()
        } detail: {
            // Detail: active transcript or placeholder
            if let transcript = appState.activeTranscript {
                TranscriptDetailView(transcript: transcript)
            } else {
                ContentUnavailableView {
                    Label("Ready to Transcribe", systemImage: "mic")
                } description: {
                    Text("Press the record button or use the global hotkey to start dictating.")
                }
            }
        }
        .navigationTitle(AppConstants.appName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RecordButton()
            }
        }
        .task {
            // Request mic permission on first launch
            if !appState.permissions.hasMicrophonePermission {
                _ = await appState.permissions.requestMicrophoneAccess()
            }
            // Load transcript history
            appState.loadTranscripts()
        }
    }
}

/// Record/stop button in the toolbar.
struct RecordButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            // TODO: M1 — Wire to TranscriptionPipeline
        } label: {
            Label(
                appState.pipelineState == .recording ? "Stop" : "Record",
                systemImage: appState.pipelineState == .recording ? "stop.circle.fill" : "mic.circle.fill"
            )
        }
        .disabled(appState.pipelineState.isActive && appState.pipelineState != .recording)
        .help("Start or stop recording")
    }
}
