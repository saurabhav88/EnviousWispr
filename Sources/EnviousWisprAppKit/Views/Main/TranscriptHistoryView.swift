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
          // Paint the row background with the page colour so macOS's default
          // grey selection highlight is replaced — our card's accent ring is the
          // only selection signal.
          .listRowBackground(Color.stPageBg)
          .listRowSeparator(.hidden)
          .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(Color.stPageBg)
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

/// A single row in the transcript history list, rendered as a bordered card.
/// The selected card carries an accent ring and a dot on its timestamp (mockup
/// #27); selection state is derived from the coordinator, not a new feature.
struct TranscriptRowView: View {
  let transcript: Transcript
  @Environment(TranscriptCoordinator.self) private var transcriptCoordinator

  private var isSelected: Bool {
    transcriptCoordinator.selectedTranscriptID == transcript.id
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 5) {
        if isSelected {
          Circle()
            .fill(Color.stAccent)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
        }
        Text(transcript.createdAt, format: .dateTime.month().day().hour().minute())
          .font(.caption.monospaced())
          .foregroundStyle(.stTextSecondary)
      }

      Text(transcript.displayText)
        .lineLimit(3)
        .font(.body)
        .foregroundStyle(.stTextPrimary)

      HStack(spacing: 6) {
        if transcript.isRecovered == true {
          // #1063 PR2 — marks a transcript reconstructed from a recovered recording
          // after an abnormal exit. Icon + text (never color-only).
          HStack(spacing: 2) {
            Image(systemName: "arrow.clockwise.circle")
            Text("Recovered")
          }
          .font(.caption2)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(Color.stSuccess.opacity(0.15), in: Capsule())
          .foregroundStyle(.stSuccess)
          .accessibilityLabel("Recovered recording")
        }

        if transcript.inputDeviceWasRemoved == true {
          // #1408 — the microphone died mid-recording and this is what survived,
          // so the text may be cut short. `stWarning`, not `stSuccess`:
          // "Recovered" is good news, "Interrupted" is not. Icon + text (never
          // color-only). The crossed-out mic names the event the user watched
          // happen; `scissors` would read as if they trimmed it themselves —
          // and it renders ONLY for a verified removal, never for other
          // interruption causes (the field takes the strictest predicate).
          HStack(spacing: 2) {
            Image(systemName: "mic.slash.circle")
            Text("Interrupted")
          }
          .font(.caption2)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(Color.stWarning.opacity(0.15), in: Capsule())
          .foregroundStyle(.stWarning)
          .accessibilityLabel("Interrupted recording")
        }

        if transcript.polishedText != nil {
          HStack(spacing: 2) {
            Image(systemName: "sparkles")
            Text(transcript.llmModel ?? "AI")
          }
          .font(.caption2)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(Color.stAccent.opacity(0.16), in: Capsule())
          .foregroundStyle(.stAccent)
        }

        Text(transcript.backendType.displayName)
          .font(.caption2)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(Color.stTextSecondary.opacity(0.14), in: Capsule())
          .foregroundStyle(.stTextSecondary)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      // Opaque base so nothing bleeds through, plus a faint accent wash when
      // selected (matches the mockup's subtly purple-tinted active card).
      ZStack {
        RoundedRectangle(cornerRadius: 12).fill(Color.stSectionBg)
        if isSelected {
          RoundedRectangle(cornerRadius: 12).fill(Color.stAccent.opacity(0.12))
        }
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(
          isSelected ? Color.stAccent : Color.stDivider,
          lineWidth: isSelected ? 2 : 1)
    )
    .contentShape(RoundedRectangle(cornerRadius: 12))
  }
}
