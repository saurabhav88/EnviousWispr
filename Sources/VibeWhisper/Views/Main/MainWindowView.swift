import SwiftUI

/// Primary transcript window.
struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @State private var showOnboarding = false

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

            // Show onboarding if needed
            if !appState.hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
                .environment(appState)
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
                    VStack(spacing: 4) {
                        Text("Press the record button to start dictating.")
                        if appState.hotkeyEnabled {
                            Text("Hotkey: \(appState.hotkeyService.hotkeyDescription)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

            case .recording:
                VStack(spacing: 16) {
                    // Pulsing rings behind mic icon
                    ZStack {
                        PulsingRingsView()
                            .frame(width: 120, height: 120)

                        Image(systemName: "mic.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.red)
                    }

                    Text("Recording...")
                        .font(.title2)
                        .bold()

                    // Waveform visualizer
                    WaveformView(level: appState.audioLevel)
                        .frame(height: 32)
                        .padding(.horizontal, 60)

                    // Audio level bar
                    AudioLevelBar(level: appState.audioLevel)
                        .frame(height: 6)
                        .padding(.horizontal, 80)

                    if appState.vadAutoStop {
                        Text("Auto-stop on silence enabled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        .animation(.easeInOut(duration: 0.3), value: appState.pipelineState)
    }
}

/// Animated pulsing rings for recording indicator.
struct PulsingRingsView: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(.red.opacity(0.3), lineWidth: 2)
                    .scaleEffect(animate ? 1.5 + CGFloat(i) * 0.3 : 1.0)
                    .opacity(animate ? 0 : 0.6)
                    .animation(
                        .easeOut(duration: 1.5)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.4),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
        .onDisappear { animate = false }
    }
}

/// Waveform bars visualizer for audio level.
struct WaveformView: View {
    let level: Float
    private let barCount = 16

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor)
                    .frame(width: 3, height: barHeight(for: i))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }

    private var barColor: Color {
        if level > 0.7 { return .red }
        if level > 0.4 { return .orange }
        return .green
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalized = CGFloat(level)
        let center = CGFloat(barCount) / 2.0
        let distance = abs(CGFloat(index) - center) / center
        let base: CGFloat = 3
        let maxHeight: CGFloat = 28
        return base + (maxHeight - base) * normalized * (1.0 - distance * 0.6)
    }
}

/// Simple horizontal audio level bar.
struct AudioLevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.secondary.opacity(0.2))

                RoundedRectangle(cornerRadius: 3)
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
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Image(systemName: appState.pipelineState.menuBarIconName)
                .foregroundStyle(appState.pipelineState == .recording ? .red : .secondary)
            Text(appState.pipelineState.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .animation(.easeInOut(duration: 0.2), value: appState.pipelineState)
    }

    private var statusColor: Color {
        switch appState.pipelineState {
        case .idle: return .secondary
        case .recording: return .red
        case .transcribing, .polishing: return .orange
        case .complete: return .green
        case .error: return .red
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
