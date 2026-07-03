import EnviousWisprASR
import EnviousWisprCore
import SwiftUI

/// Stats header shown above the transcript list in the sidebar.
struct SidebarStatsHeader: View {
  @Environment(TranscriptCoordinator.self) private var transcriptCoordinator
  // PR7 of #763: live phase + display labels resolve through the three new homes.
  @Environment(LiveRecordingState.self) private var liveRecordingState
  @Environment(BackendMetadata.self) private var backendMetadata
  @Environment(\.asrManager) private var asrManagerEnv

  /// Force-unwrapped: `EnviousWisprApp` always injects a real instance into the
  /// environment (see `AppEnvironmentKeys.swift`).
  private var asrManager: any ASRManagerInterface { asrManagerEnv! }

  private var isRecording: Bool {
    liveRecordingState.pipelineState == .recording
  }

  var body: some View {
    @Bindable var tc = transcriptCoordinator

    VStack(spacing: 10) {
      // Search bar + transcript count row
      HStack(spacing: 8) {
        HStack(spacing: 4) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.stTextTertiary)
          TextField("Search transcripts", text: $tc.searchQuery)
            .textFieldStyle(.plain)
            .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 6))

        Text("\(transcriptCoordinator.transcriptCount)")
          .font(.caption.bold())
          .foregroundStyle(.stTextSecondary)
          .monospacedDigit()
      }
      .opacity(isRecording ? 0.4 : 1.0)

      // Model status bar
      ModelStatusBar(
        modelName: backendMetadata.modelLabel,
        statusText: backendMetadata.statusText(for: liveRecordingState.pipelineState),
        polishLabel: backendMetadata.polishLabel,
        isRecording: isRecording,
        isLoaded: asrManager.isModelLoaded,
        hasError: {
          if case .error = liveRecordingState.pipelineState { return true }
          return false
        }()
      )
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 8)
    .animation(.easeInOut(duration: 0.3), value: isRecording)
  }
}

/// Compact two-row status card: transcription engine + configured AI polish.
/// `polishLabel` is a settings readout (configured target), not a runtime
/// health signal — see `BackendMetadata.polishLabel`.
struct ModelStatusBar: View {
  let modelName: String
  let statusText: String
  let polishLabel: String
  let isRecording: Bool
  let isLoaded: Bool
  let hasError: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Circle()
          .fill(dotColor)
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)

        Text("Engine")
          .font(.caption)
          .foregroundStyle(.stTextSecondary)
          .layoutPriority(1)

        Spacer(minLength: 8)

        Text(modelName)
          .font(.caption)
          .fontWeight(.medium)
          .foregroundStyle(.stTextPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(modelName)

        Text("·")
          .foregroundStyle(.stTextTertiary)

        Text(statusText)
          .font(.caption)
          .foregroundStyle(.stTextSecondary)
          .lineLimit(1)
          .layoutPriority(1)
      }

      HStack(spacing: 6) {
        Color.clear
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)

        Text("AI Polish")
          .font(.caption)
          .foregroundStyle(.stTextSecondary)
          .layoutPriority(1)

        Spacer(minLength: 8)

        Text(polishLabel)
          .font(.caption)
          .fontWeight(.medium)
          .foregroundStyle(.stTextPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(polishLabel)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(
          isRecording
            ? AnyShapeStyle(Color.stError.opacity(0.1)) : AnyShapeStyle(Color.stSectionBg))
    )
    .accessibilityElement(children: .combine)
  }

  private var dotColor: Color {
    if isRecording { return .stError }
    if hasError { return .stError }
    return isLoaded ? .stSuccess : .stTextTertiary
  }
}
