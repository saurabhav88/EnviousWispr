import EnviousWisprCore
import SwiftUI

/// Sidebar list of past transcripts with stats header and search.
struct TranscriptHistoryView: View {
  @Environment(TranscriptCoordinator.self) private var transcriptCoordinator
  // PR7 of #763: live phase resolves through LiveRecordingState.
  @Environment(LiveRecordingState.self) private var liveRecordingState
  @State private var showDeleteAllConfirmation = false

  private var isRecording: Bool {
    liveRecordingState.pipelineState == .recording
  }

  var body: some View {
    @Bindable var tc = transcriptCoordinator

    VStack(spacing: 0) {
      SidebarStatsHeader()

      Divider()

      List(
        transcriptCoordinator.filteredTranscripts,
        selection: $tc.selectedTranscriptID
      ) { transcript in
        TranscriptRowView(transcript: transcript)
          .tag(transcript.id)
      }
      .opacity(isRecording ? 0.4 : 1.0)
      .animation(.easeInOut(duration: 0.3), value: isRecording)
      .overlay {
        if transcriptCoordinator.transcripts.isEmpty {
          ContentUnavailableView(
            "No Transcripts Yet",
            systemImage: "doc.text",
            description: Text("Your transcription history will appear here.")
          )
        }
      }

      if !transcriptCoordinator.transcripts.isEmpty {
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
      Button("Cancel", role: .cancel) {}
      Button("Delete All", role: .destructive) {
        transcriptCoordinator.deleteAll()
      }
    } message: {
      Text(
        "This will permanently delete all \(transcriptCoordinator.transcriptCount) transcripts. This action cannot be undone."
      )
    }
  }
}

/// A single row in the transcript history list.
struct TranscriptRowView: View {
  let transcript: Transcript

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(transcript.createdAt, format: .dateTime.month().day().hour().minute())
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

        Text(transcript.backendType.displayName)
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
