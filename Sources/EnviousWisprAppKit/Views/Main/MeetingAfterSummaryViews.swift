import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import SwiftUI

/// A summary drawn read-only from its lines (`HistoryMeetingAfterView.readableBlocks`): headings
/// as the structured summary draws section titles, bullets with a bullet, paragraphs as body
/// text. Inline emphasis is kept; links are removed (`readable`).
/// Also draws both sides of the summary comparison sheet (#4611).
struct MeetingReadableSummary: View {
  let blocks: [HistoryMeetingAfterView.ReadableBlock]

  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .heading(let title):
          Text(verbatim: title.uppercased())
            .font(.stSectionHeader)
            .tracking(0.6)
            .foregroundStyle(.stAccent)
            .padding(.top, DesignSpacing.sm)
            .accessibilityAddTraits(.isHeader)
        case .bullet(let line):
          HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
            Text(verbatim: "•").foregroundStyle(.stTextSecondary).accessibilityHidden(true)
            lineText(line)
          }
        case .paragraph(let line):
          lineText(line)
        case .gap:
          Color.clear.frame(height: DesignSpacing.xs)
        }
      }
    }
    .textSelection(.enabled)
  }

  private func lineText(_ line: String) -> some View {
    Text(HistoryMeetingAfterView.readable(line))
      .font(.stCardText)
      .foregroundStyle(.stTextBody)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// The structured summary: sections and items. View source appears only for an item whose
/// sources the validator accepted now and that still lead to a shown turn or an existing note;
/// "from your notes" only when every accepted source is a note.
struct MeetingAfterSummarySections: View {
  let meetingID: UUID
  let document: MeetingSummaryDocument
  let references: any MeetingSummaryReferencing
  let visibleTurnIDs: Set<String>
  let noteBlockIDs: Set<UUID>
  /// The meeting time of a source, for its link's words.
  let sourceMs: (MeetingAfterPresentation.SourceTarget) -> Int?
  let onViewSource: (MeetingAfterPresentation.SourceTarget) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.xl) {
      ForEach(document.sections) { section in
        VStack(alignment: .leading, spacing: DesignSpacing.md) {
          Text(verbatim: section.title.uppercased())
            .font(.stSectionHeader)
            .tracking(0.6)
            .foregroundStyle(.stAccent)
          ForEach(section.items) { item in
            itemRow(item)
          }
        }
      }
    }
  }

  private func itemRow(_ item: MeetingSummaryItem) -> some View {
    let sources = references.validatedSource(for: item.id, meetingID: meetingID)?.sources ?? []
    let target = MeetingAfterPresentation.sourceTarget(
      sources, visibleTurnIDs: visibleTurnIDs, noteBlockIDs: noteBlockIDs)
    return HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.sm) {
      Text(verbatim: "•").foregroundStyle(.stTextSecondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        Text(verbatim: item.text)
          .font(.stCardText)
          .foregroundStyle(.stTextBody)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        // #4611 D12: one small link naming the place ("Your notes · 0:28", "Transcript · 0:00");
        // it shows and highlights the source and never starts playback.
        if let target {
          MeetingSourceLink(place: Self.place(target, ms: sourceMs(target))) {
            onViewSource(target)
          }
        } else if MeetingAfterPresentation.isFromNotes(sources) {
          Text(
            "from your notes",
            comment: "History meeting summary: the item came from the user's notes."
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        }
      }
    }
  }
}

extension MeetingAfterSummarySections {
  /// "Your notes · 0:28", "Transcript · 0:00", or the place alone when it has no time.
  static func place(_ target: MeetingAfterPresentation.SourceTarget, ms: Int?) -> String {
    let name =
      switch target {
      case .note:
        String(
          localized: "Your notes",
          comment: "History meeting summary: a source link's place, the notes.")
      case .turn:
        String(
          localized: "Transcript",
          comment: "History meeting summary: a source link's place, the transcript.")
      }
    guard let ms else { return name }
    return "\(name) · \(MeetingsPresentation.clock(ms: ms))"
  }
}

/// #4611 D12: a summary item's source, as one small secondary link with a chevron.
private struct MeetingSourceLink: View {
  let place: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: DesignSpacing.xxs) {
        Text(verbatim: place)
        Image(systemName: "chevron.right")
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      .font(.stHelper)
      .foregroundStyle(hovering ? Color.stAccent : Color.stTextSecondary)
      .padding(.vertical, 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(
      Text(
        "Show where this came from",
        comment: "History meeting summary: hover hint on a summary item's source link.")
    )
    .accessibilityLabel(
      Text(
        "Show source: \(place)",
        comment:
          "History meeting summary, VoiceOver: a source link. %@ is the place, like Your notes · 0:28."
      ))
  }
}
