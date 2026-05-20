import EnviousWisprASR
import EnviousWisprCore
import SwiftUI

/// Stats header shown above the transcript list in the sidebar.
struct SidebarStatsHeader: View {
  @Environment(TranscriptWorkflowCoordinator.self) private var transcriptWorkflowCoordinator
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
    @Bindable var tc = transcriptWorkflowCoordinator.transcriptCoordinator

    VStack(spacing: 10) {
      // Search bar + transcript count row
      HStack(spacing: 8) {
        HStack(spacing: 4) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Search transcripts", text: $tc.searchQuery)
            .textFieldStyle(.plain)
            .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 6))

        Text("\(transcriptWorkflowCoordinator.transcriptCoordinator.transcriptCount)")
          .font(.caption.bold())
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .opacity(isRecording ? 0.4 : 1.0)

      // Model status bar
      ModelStatusBar(
        modelName: backendMetadata.modelLabel,
        statusText: backendMetadata.statusText(for: liveRecordingState.pipelineState),
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

/// Compact status bar showing model name and state.
struct ModelStatusBar: View {
  let modelName: String
  let statusText: String
  let isRecording: Bool
  let isLoaded: Bool
  let hasError: Bool

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(dotColor)
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)

      Text(modelName)
        .font(.caption)
        .fontWeight(.medium)

      Text("·")
        .foregroundStyle(.tertiary)

      Text(statusText)
        .font(.caption)
        .foregroundStyle(.secondary)

      Spacer()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(
          isRecording ? AnyShapeStyle(Color.stError.opacity(0.1)) : AnyShapeStyle(.fill.quinary))
    )
  }

  private var dotColor: Color {
    if isRecording { return .stError }
    if hasError { return .stError }
    return isLoaded ? .stSuccess : .secondary
  }
}
