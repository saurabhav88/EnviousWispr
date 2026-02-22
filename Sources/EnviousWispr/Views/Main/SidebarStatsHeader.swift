import SwiftUI

/// Stats header shown above the transcript list in the sidebar.
struct SidebarStatsHeader: View {
    @Environment(AppState.self) private var appState

    private var isRecording: Bool {
        appState.pipelineState == .recording
    }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 10) {
            // Search bar + transcript count row
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search transcripts", text: $state.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 6))

                Text("\(appState.transcriptCount)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .opacity(isRecording ? 0.4 : 1.0)

            // Model status bar
            ModelStatusBar(
                modelName: appState.activeModelName,
                statusText: appState.modelStatusText,
                isRecording: isRecording,
                isLoaded: appState.asrManager.isModelLoaded,
                hasError: {
                    if case .error = appState.pipelineState { return true }
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
                .fill(isRecording ? AnyShapeStyle(.red.opacity(0.1)) : AnyShapeStyle(.fill.quinary))
        )
    }

    private var dotColor: Color {
        if isRecording { return .red }
        if hasError { return .red }
        return isLoaded ? .green : .secondary
    }
}
