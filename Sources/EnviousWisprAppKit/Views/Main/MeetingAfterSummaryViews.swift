import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import SwiftUI

/// A summary drawn read-only from its lines (`readableBlocks`): headings
/// as the structured summary draws section titles, bullets with a bullet, paragraphs as body
/// text. Inline emphasis is kept; links are removed (`readable`).
/// Also draws both sides of the summary comparison sheet (#4611).
struct MeetingReadableSummary: View {
  let blocks: [ReadableBlock]

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
    Text(Self.readable(line))
      .font(.stCardText)
      .foregroundStyle(.stTextBody)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// One line of a summary drawn read-only: a heading (`#` to `######`), a bullet (`- `, `* `,
  /// `+ `), a paragraph line, or a gap between paragraphs (UAT: the read mode showed the raw
  /// Markdown markers).
  enum ReadableBlock: Equatable {
    case heading(String)
    case bullet(String)
    case paragraph(String)
    case gap
  }

  /// The summary's lines as headings, bullets and paragraphs, markers removed, in order. Runs of
  /// blank lines become one gap; leading and trailing gaps are dropped.
  static func readableBlocks(_ markdown: String) -> [ReadableBlock] {
    var blocks: [ReadableBlock] = []
    for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      let block: ReadableBlock
      if line.isEmpty {
        block = .gap
      } else if let heading = headingText(line) {
        block = .heading(heading)
      } else if let marker = ["- ", "* ", "+ "].first(where: line.hasPrefix) {
        block = .bullet(String(line.dropFirst(marker.count)))
      } else {
        block = .paragraph(line)
      }
      if block == .gap, blocks.last == .gap || blocks.isEmpty { continue }
      blocks.append(block)
    }
    if blocks.last == .gap { blocks.removeLast() }
    return blocks
  }

  /// The text of a Markdown heading line (one to six `#`, then a space), or nil.
  private static func headingText(_ line: String) -> String? {
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let rest = line.dropFirst(hashes)
    guard rest.first == " " else { return nil }
    return rest.trimmingCharacters(in: .whitespaces)
  }

  /// The summary's Markdown with inline emphasis kept and its lines as written; plain text when
  /// it does not parse. No run carries its own font, so the 14 pt body size holds.
  /// Links are removed: only View source, after validation, may lead anywhere.
  static func readable(_ markdown: String) -> AttributedString {
    var text =
      (try? AttributedString(
        markdown: markdown,
        options: AttributedString.MarkdownParsingOptions(
          interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(markdown)
    text.link = nil
    return text
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
