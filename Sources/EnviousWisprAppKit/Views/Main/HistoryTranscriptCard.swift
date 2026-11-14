import EnviousWisprCore
import SwiftUI

/// One imported transcript in the Transcripts tab (#3147 PR3 §3.5, approved mock
/// Transcripts.dc.html): the file name, its length and the time it was saved, Open, one line
/// about the original file (with Locate original when it is unavailable), a two-line preview,
/// and the status chips the legacy row showed (file name, speakers, Recovered, Interrupted, the
/// polish model, the speech engine).
///
/// **Open and Locate original are sibling buttons**, never one inside the other, so each keeps
/// its own keyboard focus and VoiceOver action. The card itself is not a button.
///
/// **The original file is looked up off the body**: once when the card appears and whenever the
/// source owner bumps the row's revision. Nothing is drawn until the answer arrives, so the card
/// never flashes a claim it has not checked. The card never opens a player.
struct HistoryTranscriptCard: View {
  let rowID: UUID
  let sources: any ImportedSourceAccessing
  let onOpen: () -> Void
  let onLocate: () -> Void

  init(
    rowID: UUID,
    sources: any ImportedSourceAccessing,
    onOpen: @escaping () -> Void,
    onLocate: @escaping () -> Void
  ) {
    self.rowID = rowID
    self.sources = sources
    self.onOpen = onOpen
    self.onLocate = onLocate
  }

  @Environment(TranscriptCoordinator.self) private var transcripts
  @State private var sourceState: ImportedSourceState?

  private typealias P = HistoryTranscriptPresentation

  private struct SourceKey: Equatable {
    let rowID: UUID
    let revision: Int
    let reference: ImportedSourceReference?
  }

  var body: some View {
    if let row = transcripts.currentRow(id: rowID) {
      card(row)
        .task(
          id: SourceKey(
            rowID: rowID, revision: sources.revision(for: rowID),
            reference: ImportedSourceReference(row))
        ) {
          let state = await sources.state(for: rowID)
          guard !Task.isCancelled else { return }
          sourceState = state
        }
    }
  }

  private func card(_ row: Transcript) -> some View {
    let line = cardSourceLine
    return VStack(alignment: .leading, spacing: DesignSpacing.md) {
      HStack(alignment: .top, spacing: DesignSpacing.lg) {
        VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
          Text(verbatim: P.title(for: row))
            .font(.stRowTitle)
            .foregroundStyle(.stTextPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
          if let length = P.lengthLine(for: row) {
            Text(verbatim: length)
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Button(action: onOpen) {
          EnviousButtonLabel(
            LocalizedStringResource(
              "Open", comment: "History transcript card: opens the full transcript."),
            size: .medium, trailingSystemImage: "chevron.right")
        }
        .settingsButton(.outlined, size: .medium, isEnabled: true)
        .accessibilityLabel(
          Text(
            "Open \(P.title(for: row))",
            comment: "History transcript card: VoiceOver label of Open. %@ is the file name."))
      }
      sourceRow(line)
      Text(verbatim: row.historyText)
        .font(.stBody)
        .foregroundStyle(.stTextBody)
        .lineLimit(2)
      chips(row)
    }
    .historyRowCard(isSelected: false)
  }

  /// The card never opens a player, so it promises playback only for a proven original; an
  /// older row's unproven file offers Locate original with its confirmation instead.
  private var cardSourceLine: P.SourceLine {
    P.sourceLine(state: sourceState, playable: isAvailable)
  }

  private var isAvailable: Bool {
    if case .available = sourceState { return true }
    return false
  }

  @ViewBuilder
  private func sourceRow(_ line: P.SourceLine) -> some View {
    if let text = P.cardLine(line) {
      HStack(spacing: DesignSpacing.md) {
        Image(systemName: line == .plays ? "link" : "waveform.slash")
          .accessibilityHidden(true)
        Text(verbatim: text)
          .frame(maxWidth: .infinity, alignment: .leading)
        if P.offersLocate(line) {
          // A sibling of Open, never nested in it.
          Button(action: onLocate) {
            EnviousButtonLabel(
              LocalizedStringResource(
                "Locate original…",
                comment: "History transcript: choose where the original audio or video file is now."
              ),
              size: .medium)
          }
          .settingsButton(.quiet, size: .medium, isEnabled: true)
        }
      }
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    }
  }

  private func chips(_ row: Transcript) -> some View {
    WrappingHStack(spacing: DesignSpacing.sm) {
      // #2087: held countdown or Kept, from the shared Escape Recovery badge view.
      EscapeRecoveryBadge(transcript: row)
      ForEach(P.chips(for: row), id: \.self) { chip in
        chipView(chip)
      }
    }
  }

  @ViewBuilder
  private func chipView(_ chip: P.Chip) -> some View {
    switch chip {
    case .file(let name):
      // #2772 finding 11: the file name is the label, not the word "Imported".
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: "doc.badge.plus").accessibilityHidden(true)
        Text(verbatim: name)
      }
      .lineLimit(1)
      .truncationMode(.middle)
      .historyChip(tint: .stAccent, fill: Color.stAccentLight)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        Text(
          "Imported from \(name)",
          comment: "History transcript card: VoiceOver label of the file chip. %@ is the file name."
        ))
    case .speakers(let names):
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: "person.2").accessibilityHidden(true)
        Text(verbatim: names)
      }
      .lineLimit(1)
      .truncationMode(.middle)
      .historyChip(tint: .stTextSecondary, fill: Color.stTextSecondary.opacity(0.14))
    case .recovered:
      // #1063 PR2: rebuilt from a recovered recording. Icon and text, never colour alone.
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: "arrow.clockwise.circle").accessibilityHidden(true)
        Text("Recovered")
      }
      .historyChip(tint: .stSuccess, fill: Color.stSuccess.opacity(0.15))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Recovered recording")
    case .interrupted:
      // #1408: shown only for a verified device removal, never another cause.
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: "mic.slash.circle").accessibilityHidden(true)
        Text("Interrupted")
      }
      .historyChip(tint: .stWarning, fill: Color.stWarning.opacity(0.15))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Interrupted recording")
    case .polish(let model):
      HStack(spacing: DesignSpacing.xxs) {
        Image(systemName: "sparkles").accessibilityHidden(true)
        Text(verbatim: model ?? "AI")
      }
      .historyChip(tint: .stAccent, fill: Color.stAccent.opacity(0.16))
    case .backend(let name):
      Text(verbatim: name)
        .historyChip(tint: .stTextSecondary, fill: Color.stTextSecondary.opacity(0.14))
    }
  }
}
