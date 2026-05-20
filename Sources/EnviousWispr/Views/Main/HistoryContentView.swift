import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Inner content for the History tab: transcript list (left) + detail/status (right).
struct HistoryContentView: View {
  @Environment(PermissionsService.self) private var permissions
  @Environment(TranscriptWorkflowCoordinator.self) private var transcriptWorkflowCoordinator
  // PR7 of #763: live-recording fallback transcript comes from LiveRecordingState.
  @Environment(LiveRecordingState.self) private var liveRecordingState

  /// PR7 of #763: compose the displayed transcript inline. History selection
  /// from `TranscriptCoordinator` wins over the in-flight live fallback —
  /// same priority the pre-PR7 root-state getter delivered.
  private var displayedTranscript: Transcript? {
    let tc = transcriptWorkflowCoordinator.transcriptCoordinator
    if let selected = tc.selectedTranscriptID,
      let match = tc.transcripts.first(where: { $0.id == selected })
    {
      return match
    }
    return liveRecordingState.currentTranscript
  }

  var body: some View {
    VStack(spacing: 0) {
      if permissions.shouldShowAccessibilityWarning {
        AccessibilityWarningBanner()
      }

      HSplitView {
        TranscriptHistoryView()
          .frame(minWidth: 120, idealWidth: 200, maxWidth: 280)

        Group {
          if let transcript = displayedTranscript {
            TranscriptDetailView(transcript: transcript)
          } else {
            StatusView()
          }
        }
        .frame(minWidth: 260, idealWidth: 420, maxWidth: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      transcriptWorkflowCoordinator.transcriptCoordinator.load()
    }
  }
}
