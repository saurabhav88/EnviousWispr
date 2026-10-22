import EnviousWisprCore
import SwiftUI

/// The EnviousMeet page's list of meetings, newest first (#3972 §3.8). Shows what
/// `MeetingCoordinator` has saved, never a guess: a meeting a newer build wrote is listed as
/// such and offers nothing. Rows are user content and never appear in Settings search.
struct MeetingListView: View {
  @Environment(MeetingCoordinator.self) private var meetings
  @Environment(TranscriptCoordinator.self) private var transcripts
  @Binding var selectedID: UUID?

  var body: some View {
    BrandedSection(header: "Meetings") {
      if meetings.meetings.isEmpty && meetings.newerFormatMeetings.isEmpty {
        Text(
          "Your meetings appear here after you stop a recording.",
          comment: "EnviousMeet: the meeting list before any meeting was recorded."
        )
        .font(.stBody)
        .foregroundStyle(.stTextSecondary)
        .padding(14)
      } else {
        VStack(spacing: 0) {
          ForEach(meetings.meetings) { record in
            Button {
              selectedID = record.id
            } label: {
              row(record)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("meetings.row")
            .accessibilityAddTraits(selectedID == record.id ? .isSelected : [])
            Divider().overlay(Color.stDivider)
          }
          ForEach(meetings.newerFormatMeetings, id: \.id) { header in
            newerFormatRow(header)
            Divider().overlay(Color.stDivider)
          }
        }
      }
    } footer: {
      EmptyView()
    }
  }

  private func row(_ record: MeetingRecord) -> some View {
    let status = MeetingsPresentation.status(record, processingID: meetings.processing?.meetingID)
    let speakers = MeetingsPresentation.speakers(
      transcripts.currentRow(id: record.transcriptID)?.speakerAnalysis)
    let details = [MeetingsPresentation.duration(ms: record.recordedDurationMs), speakers]
      .compactMap { $0 }.joined(separator: " · ")
    return HStack(spacing: 12) {
      Image(systemName: "person.2.wave.2")
        .foregroundStyle(.stAccent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(MeetingsPresentation.title(record))
          .font(.stRowTitle)
          .foregroundStyle(.stTextPrimary)
          .lineLimit(1)
        Text(details)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }
      Spacer(minLength: 8)
      statusChip(status)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(selectedID == record.id ? Color.stAccentLight : Color.clear)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  /// The status as text first; the icon only repeats it, so colour is never the only signal.
  private func statusChip(_ status: MeetingsPresentation.Status) -> some View {
    HStack(spacing: 4) {
      Image(systemName: Self.icon(status))
        .accessibilityHidden(true)
      Text(MeetingsPresentation.statusLabel(status))
    }
    .font(.stHelper)
    .foregroundStyle(status == .needsAttention ? Color.stError : Color.stTextPrimary)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Capsule().fill(Color.stAccentLight))
  }

  private static func icon(_ status: MeetingsPresentation.Status) -> String {
    switch status {
    case .recording: return "record.circle"
    case .saving, .waiting: return "clock"
    case .interrupted: return "exclamationmark.arrow.circlepath"
    case .transcribing: return "waveform"
    case .ready: return "checkmark.circle"
    case .needsAttention: return "exclamationmark.triangle"
    }
  }

  private func newerFormatRow(_ header: MeetingRecord.Header) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "person.2.wave.2")
        .foregroundStyle(.stTextTertiary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(header.createdAt.formatted(date: .abbreviated, time: .shortened))
          .font(.stRowTitle)
          .foregroundStyle(.stTextSecondary)
        Text(
          "Saved by a newer version of EnviousWispr. Update the app to open it.",
          comment: "EnviousMeet list: a meeting this version cannot read."
        )
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .accessibilityElement(children: .combine)
  }
}
