import SwiftUI

/// Sidebar list of past transcripts with stats header and search.
struct TranscriptHistoryView: View {
    @Environment(AppState.self) private var appState

    private var isRecording: Bool {
        appState.pipelineState == .recording
    }

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            SidebarStatsHeader()

            Divider()

            List(appState.filteredTranscripts, selection: $state.selectedTranscriptID) { transcript in
                TranscriptRowView(transcript: transcript)
                    .tag(transcript.id)
            }
            .opacity(isRecording ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.3), value: isRecording)
            .searchable(text: $state.searchQuery, prompt: "Search transcripts")
            .overlay {
                if appState.transcripts.isEmpty {
                    ContentUnavailableView(
                        "No Transcripts Yet",
                        systemImage: "doc.text",
                        description: Text("Your transcription history will appear here.")
                    )
                }
            }
        }
    }
}

/// A single row in the transcript history list.
struct TranscriptRowView: View {
    let transcript: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(transcript.createdAt, format: .dateTime.hour().minute())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Text(transcript.displayText)
                    .lineLimit(1)
                    .font(.body)
            }

            HStack(spacing: 6) {
                if transcript.polishedText != nil {
                    HStack(spacing: 2) {
                        Image(systemName: "sparkles")
                        Text("AI")
                    }
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.purple.opacity(0.15), in: Capsule())
                    .foregroundStyle(.purple)
                }

                if transcript.processingTime > 0 {
                    Text(String(format: "%.1fs", transcript.processingTime))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.1), in: Capsule())
                        .foregroundStyle(.blue)
                        .monospacedDigit()
                }

                Text(transcript.backendType == .parakeet ? "Parakeet" : "Whisper")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.fill.tertiary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
