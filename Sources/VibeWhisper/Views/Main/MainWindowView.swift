import SwiftUI

/// Primary transcript window.
struct MainWindowView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            // Sidebar: transcript history
            TranscriptHistoryView()
        } detail: {
            // Detail: active transcript or status view
            if let transcript = appState.activeTranscript {
                TranscriptDetailView(transcript: transcript)
            } else {
                StatusView()
            }
        }
        .navigationTitle(AppConstants.appName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RecordButton()
            }
            ToolbarItem(placement: .status) {
                StatusBadge()
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

/// Placeholder view when no transcript is active.
struct StatusView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 16) {
            switch appState.pipelineState {
            case .idle:
                ContentUnavailableView {
                    Label("Ready to Transcribe", systemImage: "mic")
                } description: {
                    Text("Press the record button to start dictating.")
                }

            case .recording:
                VStack(spacing: 12) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)

                    Text("Recording...")
                        .font(.title2)

                    // Audio level indicator
                    AudioLevelBar(level: appState.audioLevel)
                        .frame(height: 8)
                        .padding(.horizontal, 40)
                }

            case .transcribing:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Transcribing...")
                        .font(.title2)
                    Text("This may take a moment on first run while the model loads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .polishing:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Polishing...")
                        .font(.title2)
                }

            case .complete:
                ContentUnavailableView {
                    Label("Transcription Complete", systemImage: "checkmark.circle")
                } description: {
                    Text("Select a transcript from the sidebar to view it.")
                }

            case .error(let msg):
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(msg)
                } actions: {
                    Button("Try Again") {
                        appState.pipeline.reset()
                    }
                }
            }
        }
    }
}

/// Simple horizontal audio level bar.
struct AudioLevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.secondary.opacity(0.2))

                RoundedRectangle(cornerRadius: 4)
                    .fill(level > 0.7 ? .red : level > 0.4 ? .orange : .green)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.easeOut(duration: 0.05), value: level)
            }
        }
    }
}

/// Pipeline status badge in toolbar.
struct StatusBadge: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: appState.pipelineState.menuBarIconName)
                .foregroundStyle(appState.pipelineState == .recording ? .red : .secondary)
            Text(appState.pipelineState.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Record/stop button in the toolbar.
struct RecordButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            Task {
                await appState.toggleRecording()
            }
        } label: {
            Label(
                appState.pipelineState == .recording ? "Stop" : "Record",
                systemImage: appState.pipelineState == .recording ? "stop.circle.fill" : "mic.circle.fill"
            )
            .foregroundStyle(appState.pipelineState == .recording ? .red : .accentColor)
        }
        .disabled(appState.pipelineState.isActive && appState.pipelineState != .recording)
        .help(appState.pipelineState == .recording ? "Stop recording" : "Start recording")
    }
}
