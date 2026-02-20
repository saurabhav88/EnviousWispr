import SwiftUI
import Combine

/// Primary transcript window with Command Center layout.
struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            TranscriptHistoryView()
        } detail: {
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
            if !appState.permissions.hasMicrophonePermission {
                _ = await appState.permissions.requestMicrophoneAccess()
            }
            appState.loadTranscripts()

            if !appState.settings.hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
                .environment(appState)
        }
    }
}

/// Status view when no transcript is active — handles all pipeline states.
struct StatusView: View {
    @Environment(AppState.self) private var appState
    @State private var elapsed: TimeInterval = 0
    @State private var timerCancellable: AnyCancellable?
    @State private var recordingStart: Date?

    var body: some View {
        VStack(spacing: 16) {
            switch appState.pipelineState {
            case .idle:
                ContentUnavailableView {
                    Label("Ready to Transcribe", systemImage: "mic")
                } description: {
                    VStack(spacing: 4) {
                        Text("Press the record button to start dictating.")
                        if appState.settings.hotkeyEnabled {
                            Text("Hotkey: \(appState.hotkeyService.hotkeyDescription)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

            case .recording:
                VStack(spacing: 20) {
                    // Pulsing rings + mic icon + timer
                    HStack(spacing: 16) {
                        ZStack {
                            PulsingRingsView()
                                .frame(width: 80, height: 80)

                            Image(systemName: "mic.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.red)
                        }

                        Text(formatDuration(elapsed))
                            .font(.system(size: 40, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                    }

                    Text("Recording · \(appState.activeModelName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // Waveform visualizer
                    WaveformView(level: appState.audioLevel)
                        .frame(height: 36)
                        .padding(.horizontal, 40)

                    // VAD status bar
                    VStack(spacing: 4) {
                        AudioLevelBar(level: appState.audioLevel)
                            .frame(width: 240, height: 6)

                        if appState.settings.vadAutoStop {
                            Text("VAD: Active")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }

                    // Action buttons
                    HStack(spacing: 16) {
                        Button {
                            Task { await appState.toggleRecording() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.fill")
                                Text("Stop")
                            }
                            .font(.body.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.red, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)

                        Button {
                            Task { await appState.cancelRecording() }
                        } label: {
                            HStack(spacing: 4) {
                                Text("Esc")
                                    .font(.caption.monospaced())
                                Text("Cancel")
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
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
                VStack(spacing: 12) {
                    ContentUnavailableView {
                        Label("Transcription Complete", systemImage: "checkmark.circle")
                    } description: {
                        Text("Select a transcript from the sidebar to view it.")
                    }

                    if let polishError = appState.pipeline.lastPolishError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("AI polish failed: \(polishError)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
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
        .onChange(of: appState.pipelineState) { _, newState in
            if case .recording = newState {
                startTimer()
            } else {
                stopTimer()
            }
        }
    }

    private func startTimer() {
        elapsed = 0
        recordingStart = Date()
        // Update every 1 second — display only shows mm:ss, not tenths.
        // Audio level updates happen independently via AudioCaptureManager.
        timerCancellable = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                if let start = recordingStart {
                    elapsed = Date().timeIntervalSince(start)
                }
            }
    }

    private func stopTimer() {
        timerCancellable?.cancel()
        timerCancellable = nil
        recordingStart = nil
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
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
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: 4, height: barHeight(for: i))
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
        let maxHeight: CGFloat = 32
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

            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(appState.activeModelName)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .animation(.easeInOut(duration: 0.2), value: appState.pipelineState)
    }

    private var statusLabel: String {
        switch appState.pipelineState {
        case .idle: return "Ready"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .polishing: return "Polishing"
        case .complete: return "Done"
        case .error: return "Error"
        }
    }

    private var statusColor: Color {
        switch appState.pipelineState {
        case .idle: return .green
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
