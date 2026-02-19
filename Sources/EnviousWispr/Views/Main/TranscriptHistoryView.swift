import SwiftUI

/// Sidebar list of past transcripts with search.
struct TranscriptHistoryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        List(appState.filteredTranscripts, selection: $state.selectedTranscriptID) { transcript in
            TranscriptRowView(transcript: transcript)
                .tag(transcript.id)
        }
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

/// A single row in the transcript history list.
struct TranscriptRowView: View {
    let transcript: Transcript

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(transcript.displayText)
                .lineLimit(2)
                .font(.body)

            HStack {
                Text(transcript.createdAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if transcript.polishedText != nil {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }

                Text(transcript.backendType == .parakeet ? "Parakeet" : "Whisper")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.fill.tertiary, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}
