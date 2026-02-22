import SwiftUI

/// Sidebar list of past transcripts with stats header and search.
struct TranscriptHistoryView: View {
    @Environment(AppState.self) private var appState
    @State private var showDeleteAllConfirmation = false

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
            .overlay {
                if appState.transcripts.isEmpty {
                    ContentUnavailableView(
                        "No Transcripts Yet",
                        systemImage: "doc.text",
                        description: Text("Your transcription history will appear here.")
                    )
                }
            }

            if !appState.transcripts.isEmpty {
                Divider()
                Button(role: .destructive) {
                    showDeleteAllConfirmation = true
                } label: {
                    Label("Delete All", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .alert("Delete All Transcripts?", isPresented: $showDeleteAllConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                appState.deleteAllTranscripts()
            }
        } message: {
            Text("This will permanently delete all \(appState.transcriptCount) transcripts. This action cannot be undone.")
        }
    }
}

/// A single row in the transcript history list.
struct TranscriptRowView: View {
    let transcript: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(transcript.createdAt, format: .dateTime.hour().minute())
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            Text(transcript.displayText)
                .lineLimit(3)
                .font(.body)

            HStack(spacing: 6) {
                if transcript.polishedText != nil {
                    HStack(spacing: 2) {
                        Image(systemName: "sparkles")
                        Text(transcript.llmModel ?? "AI")
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
        .padding(.vertical, 8)
    }
}
