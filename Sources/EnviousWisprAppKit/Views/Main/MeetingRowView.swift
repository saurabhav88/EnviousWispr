import EnviousWisprCore
import SwiftUI

/// One meeting in the History list (#3972 R34, R45), in the same card as every row: its name,
/// then its visible lines once the transcript exists, else what is happening to it (recording,
/// transcribing, failed). Never hidden echo lines (R19).
struct MeetingRowView: View {
  let meeting: HistoryMeetingItem
  @Environment(TranscriptCoordinator.self) private var transcriptCoordinator
  @Environment(MeetingCoordinator.self) private var meetings

  private var isSelected: Bool {
    transcriptCoordinator.selectedItemID == .meeting(meeting.meetingID)
  }

  private var title: String {
    if let record = meeting.record { return MeetingsPresentation.title(record) }
    return String(
      localized: "Meeting",
      comment: "History list: a meeting recorded with EnviousMeet whose details are not available.")
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
        Text(meeting.createdAt, format: .dateTime.month().day().hour().minute())
          .font(.caption.monospaced())
          .foregroundStyle(.stTextSecondary)
      }

      Text(title)
        .font(.body.weight(.semibold))
        .foregroundStyle(.stTextPrimary)
        .lineLimit(1)

      summaryLine
        .lineLimit(2)
        .font(.body)
        .foregroundStyle(.stTextSecondary)

      WrappingHStack(spacing: 6) {
        HStack(spacing: 2) {
          Image(systemName: "person.2.wave.2")
          Text(
            "Recording",
            comment: "History list: the kind badge of a meeting recorded with EnviousMeet.")
        }
        .font(.caption2)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.stTextSecondary.opacity(0.14), in: Capsule())
        .foregroundStyle(.stTextSecondary)

        if let record = meeting.record, record.recordedDurationMs > 0 {
          Text(MeetingsPresentation.duration(ms: record.recordedDurationMs))
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.stTextSecondary.opacity(0.14), in: Capsule())
            .foregroundStyle(.stTextSecondary)
        }

        if let speakers = MeetingsPresentation.speakers(meeting.row?.speakerAnalysis) {
          Text(speakers)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.stTextSecondary.opacity(0.14), in: Capsule())
            .foregroundStyle(.stTextSecondary)
        }
      }
    }
    .historyRowCard(isSelected: isSelected)
  }

  /// The transcript's visible lines when the meeting is ready, else its status.
  @ViewBuilder private var summaryLine: some View {
    if let record = meeting.record, record.state != .ready {
      let status = MeetingsPresentation.status(record, processingID: meetings.processing?.meetingID)
      Text(MeetingsPresentation.statusLabel(status))
        .foregroundStyle(status == .needsAttention ? Color.stError : Color.stTextSecondary)
    } else if let row = meeting.row {
      Text(MeetingHistoryPresentation.previewText(transcriptCoordinator.meetingProjection(of: row)))
    }
  }
}
