import SwiftUI

/// Stats header shown above the transcript list in the sidebar.
struct SidebarStatsHeader: View {
    @Environment(AppState.self) private var appState

    private var isRecording: Bool {
        appState.pipelineState == .recording
    }

    var body: some View {
        VStack(spacing: 10) {
            // Stat cards
            HStack(spacing: 10) {
                StatCard(
                    value: "\(appState.transcriptCount)",
                    label: "Transcripts",
                    color: .green
                )

                StatCard(
                    value: appState.averageProcessingSpeed > 0
                        ? String(format: "%.1fs", appState.averageProcessingSpeed)
                        : "—",
                    label: "Avg Speed",
                    color: .blue
                )
            }
            .opacity(isRecording ? 0.4 : 1.0)

            // Model status bar
            ModelStatusBar(
                modelName: appState.activeModelName,
                statusText: appState.modelStatusText,
                isRecording: isRecording,
                isLoaded: appState.asrManager.isModelLoaded
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.3), value: isRecording)
    }
}

/// Rounded stat card for the sidebar header.
struct StatCard: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).bold())
                .foregroundStyle(color)
                .monospacedDigit()

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Compact status bar showing model name and state.
struct ModelStatusBar: View {
    let modelName: String
    let statusText: String
    let isRecording: Bool
    let isLoaded: Bool

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
        return isLoaded ? .green : .secondary
    }
}
