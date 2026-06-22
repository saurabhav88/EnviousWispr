import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Status view when no transcript is active — handles all pipeline states.
struct StatusView: View {
  @Environment(SettingsManager.self) private var settings
  // PR7 of #763: live phase, audio level, model label, polish error all
  // resolve through the three new homes.
  @Environment(LiveRecordingState.self) private var liveRecordingState
  @Environment(LastRecordingResult.self) private var lastRecordingResult
  @Environment(BackendMetadata.self) private var backendMetadata
  // PR10 of #763: recording-control surface (toggle, cancel, reset,
  // hotkey description) moved off the former root state onto DictationRuntime façade.
  @Environment(DictationRuntime.self) private var dictationRuntime
  @Environment(\.asrManager) private var asrManagerEnv
  @State private var elapsed: TimeInterval = 0
  @State private var recordingStart: Date?

  /// Force-unwrapped: `EnviousWisprApp` always injects a real instance into the
  /// environment (see `AppEnvironmentKeys.swift`).
  private var asrManager: any ASRManagerInterface { asrManagerEnv! }

  var body: some View {
    VStack(spacing: 16) {
      switch liveRecordingState.pipelineState {
      case .idle:
        ContentUnavailableView {
          Label("Ready to Transcribe", systemImage: "mic")
        } description: {
          VStack(spacing: 4) {
            Text("Press the record button to start dictating.")
            if settings.hotkeyEnabled {
              Text("Hotkey: \(dictationRuntime.hotkeyDescription)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
          }
        }

      case .loadingModel:
        VStack(spacing: 12) {
          ProgressView()
            .controlSize(.large)
          Text("Loading model...")
            .font(.title2)
          Text("This may take a moment on first run.")
            .font(.caption)
            .foregroundStyle(.secondary)
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
                .foregroundStyle(.stError)
            }

            Text(FormattingConstants.formatDuration(elapsed))
              .font(.system(size: 40, weight: .bold, design: .monospaced))
              .foregroundStyle(.primary)
          }

          Text("Recording · \(backendMetadata.modelLabel)")
            .font(.subheadline)
            .foregroundStyle(.secondary)

          // Waveform visualizer
          WaveformView(level: liveRecordingState.audioLevel)
            .frame(height: 36)
            .padding(.horizontal, 40)

          // VAD status bar
          VStack(spacing: 4) {
            AudioLevelBar(level: liveRecordingState.audioLevel)
              .frame(width: 240, height: 6)
              .accessibilityHidden(true)

            if settings.vadAutoStop {
              Text("VAD: Active")
                .font(.caption2)
                .foregroundStyle(.stSuccess)
            }
          }

          // Action buttons
          HStack(spacing: 16) {
            Button {
              Task { await dictationRuntime.toggleRecording(source: .toolbar) }
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "stop.fill")
                Text("Stop")
              }
              .font(.body.weight(.medium))
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
              .contentShape(Rectangle())
              .background(
                RoundedRectangle(cornerRadius: 8)
                  .stroke(.stError, lineWidth: 1.5)
              )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.stError)

            Button {
              Task { await dictationRuntime.cancelRecording() }
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
          if !asrManager.isModelLoaded {
            Text("This may take a moment on first run while the model loads.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
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

          if let polishError = lastRecordingResult.polishError {
            HStack(spacing: 6) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.stWarning)
              // #945: the runner composes the full, lead-in-varied notice
              // ("AI polish failed: ..." for real errors, "AI cleanup skipped:
              // ..." for not-set-up / too-long / timeout), so render it verbatim
              // instead of hardcoding the prefix here.
              Text(polishError)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.stWarningSoft, in: RoundedRectangle(cornerRadius: 8))
          }
        }

      case .error(let msg):
        ContentUnavailableView {
          Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
          Text(msg)
        } actions: {
          Button("Try Again") {
            dictationRuntime.resetActivePipeline()
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(.easeInOut(duration: 0.3), value: liveRecordingState.pipelineState)
    .task(id: liveRecordingState.pipelineState == .recording) {
      guard liveRecordingState.pipelineState == .recording else {
        recordingStart = nil
        return
      }
      elapsed = 0
      recordingStart = Date()
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if let start = recordingStart {
          elapsed = Date().timeIntervalSince(start)
        }
      }
    }
  }

}

/// Animated pulsing rings for recording indicator.
struct PulsingRingsView: View {
  @State private var animate = false

  var body: some View {
    ZStack {
      ForEach(0..<3, id: \.self) { i in
        Circle()
          .stroke(Color.stError.opacity(0.3), lineWidth: 2)
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
    .accessibilityHidden(true)
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
    .accessibilityHidden(true)
  }

  private var barColor: Color {
    if level > 0.7 { return .stError }
    if level > 0.4 { return .stWarning }
    return .stSuccess
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
          .fill(level > 0.7 ? Color.stError : level > 0.4 ? Color.stWarning : Color.stSuccess)
          .frame(width: geo.size.width * CGFloat(level))
          .animation(.easeOut(duration: 0.05), value: level)
      }
    }
  }
}

/// Pipeline status badge in toolbar — hidden when idle/complete/error, minimal during active states.
struct StatusBadge: View {
  // PR7 of #763: live phase resolves through LiveRecordingState.
  @Environment(LiveRecordingState.self) private var liveRecordingState

  var body: some View {
    Group {
      switch liveRecordingState.pipelineState {
      case .recording:
        HStack(spacing: 4) {
          Image(systemName: "mic.fill")
            .foregroundStyle(.stError)
            .symbolEffect(.pulse)
          Text("Recording")
            .foregroundStyle(.secondary)
        }
        .font(.caption)

      case .loadingModel:
        progressLabel("Loading model\u{2026}")

      case .transcribing:
        progressLabel("Transcribing\u{2026}")

      case .polishing:
        progressLabel("Polishing\u{2026}")

      case .idle, .complete, .error:
        EmptyView()
      }
    }
    .animation(.easeInOut(duration: 0.2), value: liveRecordingState.pipelineState)
  }

  private func progressLabel(_ text: String) -> some View {
    HStack(spacing: 4) {
      ProgressView().controlSize(.small)
      Text(text).foregroundStyle(.secondary)
    }
    .font(.caption)
  }
}

/// Record/stop button in the toolbar.
struct RecordButton: View {
  // PR7 of #763: live phase resolves through LiveRecordingState.
  @Environment(LiveRecordingState.self) private var liveRecordingState
  // PR10 of #763: toggle dispatches through DictationRuntime façade.
  @Environment(DictationRuntime.self) private var dictationRuntime

  var body: some View {
    let state = liveRecordingState.pipelineState
    Button {
      Task {
        await dictationRuntime.toggleRecording(source: .toolbar)
      }
    } label: {
      Label(
        state == .recording ? "Stop" : "Record",
        systemImage: state == .recording ? "stop.circle.fill" : "mic.circle.fill"
      )
      .foregroundStyle(state == .recording ? Color.stError : Color.stAccent)
    }
    .labelStyle(.titleAndIcon)
    .disabled(state.isActive && state != .recording)
    .help(state == .recording ? "Stop recording" : "Start recording")
  }
}
